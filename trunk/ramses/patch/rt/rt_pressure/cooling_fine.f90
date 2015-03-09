subroutine cooling_fine(ilevel)
  use amr_commons
  use hydro_commons
  use cooling_module
#ifdef RT
  use rt_parameters, only: rt_UV_hom,rt_isDiffuseUVsrc
  use rt_cooling_module, only: update_UVrates
  use UV_module
#endif
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel
  !-------------------------------------------------------------------
  ! Compute cooling for fine levels
  !-------------------------------------------------------------------
  integer::ncache,i,igrid,ngrid,info
  integer,dimension(1:nvector),save::ind_grid

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Operator splitting step for cooling source term
  ! by vector sweeps
  ncache=active(ilevel)%ngrid
  do igrid=1,ncache,nvector
     ngrid=MIN(nvector,ncache-igrid+1)
     do i=1,ngrid
        ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
     end do
     call coolfine1(ind_grid,ngrid,ilevel)
  end do

  if((cooling.and..not.neq_chem).and.ilevel==levelmin.and.cosmo)then
     if(myid==1)write(*,*)'Computing new cooling table'
     call set_table(dble(aexp))
  endif
#ifdef RT
  if(neq_chem.and.ilevel==levelmin) then
     if(cosmo)call update_rt_c
     if(cosmo .and. rt_UV_hom)call update_UVrates
     if(cosmo .and. rt_isDiffuseUVsrc)call update_UVsrc
     if(ilevel==levelmin) call output_rt_stats
  endif
#endif

111 format('   Entering cooling_fine for level',i2)

end subroutine cooling_fine
!###########################################################
!###########################################################
!###########################################################
!###########################################################
subroutine coolfine1(ind_grid,ngrid,ilevel)
  use amr_commons
  use hydro_commons
  use cooling_module
#ifdef ATON
  use radiation_commons, ONLY: Erad
#endif
#ifdef RT
  use rt_parameters
  use rt_hydro_commons
  use rt_cooling_module, only: rt_solve_cooling,iIR,rt_isIRtrap &
       ,rt_pressBoost,iIRtrapVar,kappaSc,a_r,is_kIR_T,rt_vc
#endif
  implicit none
  integer::ilevel,ngrid
  integer,dimension(1:nvector)::ind_grid
  !-------------------------------------------------------------------
  !-------------------------------------------------------------------
  integer::i,ind,iskip,idim,nleaf,nx_loc,ix,iy,iz
  integer::ii,ig,iNp,il,irad
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(kind=8)::dtcool,nISM,nCOM,damp_factor,cooling_switch,t_blast
  real(dp)::polytropic_constant
  integer,dimension(1:nvector),save::ind_cell,ind_leaf
  real(kind=8),dimension(1:nvector),save::nH,delta_T2,ekk,ekk_new,err
#ifdef RT
  real(dp)::scale_Np,scale_Fp,work
  real(dp)::fmag,Npc,fred,Npnew, kScIR, EIR, TR
  real(dp),dimension(1:ndim)::Fpnew,FIR,mom_IR
  logical,dimension(1:nvector),save::cooling_on=.true.
  real(dp),dimension(1:nvector),save:: T2,T2_old
  real(dp),dimension(1:nvector, nIons),save:: xion
  real(dp),dimension(1:nvector, nGroups),save:: Np, Np_boost=0d0, dNpdt=0d0
  real(dp),dimension(1:nvector, nGroups, ndim),save:: Fp, Fp_boost, dFpdt
  real(dp),dimension(1:nvector, ndim),save:: p_gas, u_gas
#endif
  real(kind=8),dimension(1:nvector),save::T2min,Zsolar,boost
  real(dp),dimension(1:3)::skip_loc
  real(kind=8)::dx,dx_loc,scale,vol_loc
  real(kind=8)::dx_div_6, f_trap, NIRtot, NIRtrap, unit_tau, tau, Np2Ep
  real(kind=8)::EIR_trapped
  real(dp),dimension(nDim, nDim):: tEdd ! Eddington tensor
  real(dp),dimension(nDim):: flux 

  ! Mesh spacing in that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  dx_div_6 = dx_loc / 6d0
  vol_loc=dx_loc**ndim
  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
#ifdef RT
  call rt_units(scale_Np, scale_Fp)
#endif

  ! Typical ISM density in H/cc
  nISM = n_star; nCOM=0d0
  if(cosmo)then
     nCOM = del_star*omega_b*rhoc*(h0/100.)**2/aexp**3*X/mH
  endif
  nISM = MAX(nCOM,nISM)

  ! Polytropic constant for Jeans length related polytropic EOS
  if(jeans_ncells>0)then
     polytropic_constant=2d0*(boxlen*jeans_ncells*0.5d0**dble(nlevelmax)*scale_l/aexp)**2/ &
          & (twopi)*6.67e-8*scale_d*(scale_t/scale_l)**2
  endif

#ifdef RT
  if(rt_isIRtrap) then
     ! For conversion from photon number density to photon energy density:
     Np2Ep = scale_Np * group_egy(iIR) * ev_to_erg                       &
          * rt_c_cgs/c_cgs * rt_pressBoost / scale_d / scale_v**2
  endif
#endif

  ! Loop over cells
  do ind=1,twotondim
     iskip=ncoarse+(ind-1)*ngridmax
     do i=1,ngrid
        ind_cell(i)=iskip+ind_grid(i)
     end do

     ! Gather leaf cells
     nleaf=0
     do i=1,ngrid
        if(son(ind_cell(i))==0)then
           nleaf=nleaf+1
           ind_leaf(nleaf)=ind_cell(i)
        end if
     end do
     if(nleaf.eq.0)cycle

     ! Joki flooring density:
     do i=1,nleaf
        uold(ind_leaf(i),1) = max(uold(ind_leaf(i),1),smallr)
     end do

     ! Compute rho
     do i=1,nleaf
        nH(i)=MAX(uold(ind_leaf(i),1),smallr)
     end do

     do i=1,nleaf
        p_gas(i,:) = uold(ind_leaf(i),2:ndim+1) * scale_d * scale_v
        u_gas(i,:) = uold(ind_leaf(i),2:ndim+1) &
                     /uold(ind_leaf(i),1) * scale_v
     end do

     ! Compute metallicity in solar units
     if(metal)then
        do i=1,nleaf
           Zsolar(i)=uold(ind_leaf(i),imetal)/nH(i)/0.02
        end do
     else
        do i=1,nleaf
           Zsolar(i)=z_ave
        end do
     endif

#ifdef RT
     if(rt_isIRtrap) then  ! Gather also trapped photons for solve_cooling
        iNp=iGroups(iIR)
        do i=1,nleaf
           il=ind_leaf(i)
           rtuold(il,iNp) = rtuold(il,iNp) + uold(il,iIRtrapVar)/Np2Ep
           if(rt_smooth) &
                rtunew(il,iNp)= rtunew(il,iNp) + uold(il,iIRtrapVar)/Np2Ep
        end do
     endif

     if(rt_vc) then         !   Add/remove work of radiation on gas. Eq A6.
        iNp=iGroups(iIR)
        do i=1,nleaf 
           il=ind_leaf(i)
           NIRtot = rtuold(il,iNp)
           kScIR  = kappaSc(iIR)  
           if(is_kIR_T) then                      !       k_IR depends on T
              EIR = group_egy(iIR) * ev_to_erg * NIRtot *scale_Np
              TR = max(T2_min_fix,(EIR*rt_c_cgs/c_cgs/a_r)**0.25)
              kScIR  = kappaSc(iIR)  * (TR/10d0)**2
           endif
           kScIR = kScIR*scale_d*scale_l
           flux = rtuold(il,iNp+1:iNp+ndim)
           work = scale_v/c_cgs * kScIR * sum(uold(il,2:ndim+1)*flux) &
                * Zsolar(i) * dtnew(ilevel)       ! Eq A6
           
           uold(il,ndim+2) = uold(il,ndim+2) &    ! Add work to gas energy
                + work * group_egy(iIR) &
                * ev_to_erg / scale_d / scale_v**2 / scale_l**3
           
           rtuold(il,iNp) = rtuold(il,iNp) - work !Remove from rad density
           rtuold(il,iNp) = max(rtuold(il,iNp),smallnp)
           call reduce_flux(rtuold(il,iNp+1:iNp+ndim),rtuold(il,iNp)*rt_c)
        enddo
     endif
#endif
        
     do i=1,nleaf
        ekk(i)=0.0d0
     end do
     do idim=1,ndim
        do i=1,nleaf
           ekk(i)=ekk(i)+0.5*uold(ind_leaf(i),idim+1)**2/nH(i)
        end do
     end do
     do i=1,nleaf ! Prevent negative T!!!
        uold(ind_leaf(i),ndim+2) = max(uold(ind_leaf(i),ndim+2), ekk(i))
     end do
     ! Compute thermal pressure
     do i=1,nleaf
        T2(i)=uold(ind_leaf(i),ndim+2)
     end do
     do i=1,nleaf
        err(i)=0.0d0
     end do
#if NENER>0
     do irad=1,nener
        do i=1,nleaf
           err(i)=err(i)+uold(ind_leaf(i),ndim+2+irad)
        end do
     end do
#endif
     do i=1,nleaf
        T2(i)=(gamma-1.0)*(T2(i)-ekk(i)-err(i))
     end do

     ! Compute T2=T/mu in Kelvin
     do i=1,nleaf
        T2(i)=T2(i)/nH(i)*scale_T2
     end do

     ! Compute nH in H/cc
     do i=1,nleaf
        nH(i)=nH(i)*scale_nH
     end do

     ! Compute radiation boost factor
     if(self_shielding)then
        do i=1,nleaf
           boost(i)=exp(-nH(i)/0.01)
        end do
#ifdef ATON
     else if (aton) then
        do i=1,nleaf
           boost(i)=MAX(Erad(ind_leaf(i))/J0simple(aexp), &
                &                   J0min/J0simple(aexp) )
        end do
#endif
     else
        do i=1,nleaf
           boost(i)=1.0
        end do
     endif

     !==========================================
     ! Compute temperature from polytrope EOS
     !==========================================
     if(jeans_ncells>0)then
        do i=1,nleaf
           T2min(i) = nH(i)*polytropic_constant*scale_T2
        end do
     else
        do i=1,nleaf
           T2min(i) = T2_star*(nH(i)/nISM)**(g_star-1.0)
        end do
     endif
     !==========================================
     ! You can put your own polytrope EOS here
     !==========================================

     if(cooling)then
        ! Compute thermal temperature by subtracting polytrope
        do i=1,nleaf
           T2(i) = max(T2(i)-T2min(i),T2_min_fix)
        end do
     endif

     ! Compute cooling time step in second
     dtcool = dtnew(ilevel)*scale_t

#ifdef RT
     if(neq_chem) then
        ! Get the ionization fractions
        do ii=0,nIons-1
           do i=1,nleaf
              xion(i,1+ii) = uold(ind_leaf(i),iIons+ii)/uold(ind_leaf(i),1)
           end do
        end do

        ! Get photon densities and flux magnitudes
        do ig=1,nGroups
           iNp=iGroups(ig)
           do i=1,nleaf
              il=ind_leaf(i)
              Np(i,ig)        = scale_Np * rtuold(il,iNp)
              Fp(i,ig,1:ndim) = scale_Fp * rtuold(il,iNp+1:iNp+ndim)
           enddo
           if(rt_smooth) then                           ! Smooth RT update
              do i=1,nleaf !Calc addition per sec to Np, Fp for current dt
                 il=ind_leaf(i)
                 Npnew = scale_Np * rtunew(il,iNp)
                 Fpnew = scale_Fp * rtunew(il,iNp+1:iNp+ndim)
                 dNpdt(i,ig)   = (Npnew - Np(i,ig)) / dtcool
                 dFpdt(i,ig,:) = (Fpnew - Fp(i,ig,:)) / dtcool
              end do
           end if
        end do

        if(cooling .and. delayed_cooling) then
           cooling_on(1:nleaf)=.true.
           do i=1,nleaf
              if(uold(ind_leaf(i),idelay)/uold(ind_leaf(i),1) .gt. 1d-3) &
                   cooling_on(i)=.false.
           end do
        end if
        if(isothermal)cooling_on(1:nleaf)=.false.
     endif
     
     if(rt_vc) then ! Do the Lorentz boost. Eqs A4 an A5.
        do i=1,nleaf
           do ig=1,nGroups
              Npc=Np(i,ig)*rt_c_cgs
              call cmp_Eddington_tensor(Npc,Fp(i,ig,:),tEdd)
              Np_boost(i,ig) = - 2d0/c_cgs/rt_c_cgs * sum(u_gas(i,:)*Fp(i,ig,:))
              do idim=1,ndim
                 Fp_boost(i,ig,idim) =  &
                      -u_gas(i,idim)*Np(i,ig) * rt_c_cgs/c_cgs &
                      -sum(u_gas(i,:)*tEdd(idim,:))*Np(i,ig)*rt_c_cgs/c_cgs
              end do
           end do
           Np(i,:)   = Np(i,:) + Np_boost(i,:)
           Fp(i,:,:) = Fp(i,:,:) + Fp_boost(i,:,:)
        end do
     endif
#endif

     ! Compute net cooling at constant nH
     if(cooling.and..not.neq_chem)then
        call solve_cooling(nH,T2,Zsolar,boost,dtcool,delta_T2,nleaf)
     endif
#ifdef RT
     if(neq_chem) then
        T2_old(1:nleaf) = T2(1:nleaf)
        call rt_solve_cooling(T2, xion, Np, Fp, p_gas, dNpdt, dFpdt, nH &
                             ,cooling_on, Zsolar, dtcool, aexp, nleaf)
        delta_T2(1:nleaf) = T2(1:nleaf) - T2_old(1:nleaf)
     endif
#endif

     ! Compute rho
     do i=1,nleaf
        nH(i) = nH(i)/scale_nH
     end do

#ifdef RT
     if(.not. static) then
        ! Update gas momentum and kinetic energy:
        do i=1,nleaf
           uold(ind_leaf(i),2:1+ndim) = p_gas(i,:) /scale_d /scale_v
        end do
        ! Energy update ==================================================
        ! Calculate NEW pressure from updated momentum
        ekk_new(1:nleaf) = 0d0
        do i=1,nleaf
           do idim=1,ndim
              ekk_new(i) = ekk_new(i)                 &
                   +0.5*uold(ind_leaf(i),idim+1)**2   &
                   /MAX(uold(ind_leaf(i),1),smallr)    
           end do
        end do
        do i=1,nleaf                                   
           ! Update the pressure variable with the new kinetic energy:
           uold(ind_leaf(i),ndim+2) = uold(ind_leaf(i),ndim+2)           &
                                    - ekk(i) + ekk_new(i)
        end do
        do i=1,nleaf                                   
           ekk(i)=ekk_new(i)
        end do
     
        if(rt_vc) then ! Photon work: subtract from the IR ONLY radiation
           do i=1,nleaf                                   
              Np(i,iIR) = Np(i,iIR) + (ekk(i) - ekk_new(i))              &
                   /scale_d/scale_v**2 / group_egy(iIR) / ev_to_erg
           end do
        endif
        ! End energy update ==============================================
     endif ! if(.not. static)
#endif

     ! Compute net energy sink
     if(cooling.or.neq_chem)then
        do i=1,nleaf
           delta_T2(i) = delta_T2(i)*nH(i)/scale_T2/(gamma-1.0)
        end do
        ! Turn off cooling in blast wave regions
        if(delayed_cooling)then
           do i=1,nleaf
              cooling_switch = uold(ind_leaf(i),idelay)/uold(ind_leaf(i),1)
              if(cooling_switch > 1d-3)then
                 delta_T2(i) = MAX(delta_T2(i),real(0,kind=dp))
              endif
           end do
        endif
     endif

     ! Compute minimal total energy from polytrope
     do i=1,nleaf
        T2min(i) = T2min(i)*nH(i)/scale_T2/(gamma-1.0) + ekk(i) + err(i)
     end do

     ! Update total fluid energy
     do i=1,nleaf
        T2(i) = uold(ind_leaf(i),ndim+2)
     end do
     if(cooling.or.neq_chem)then
        do i=1,nleaf
           T2(i) = T2(i)+delta_T2(i)
        end do
     endif
     if(isothermal)then
        do i=1,nleaf
           uold(ind_leaf(i),ndim+2) = T2min(i)
        end do
     else
        do i=1,nleaf
           uold(ind_leaf(i),ndim+2) = max(T2(i),T2min(i))
        end do
     endif

     ! Update delayed cooling switch
     if(delayed_cooling)then
        t_blast=20d0*1d6*(365.*24.*3600.)
        damp_factor=exp(-dtcool/t_blast)
        do i=1,nleaf
           uold(ind_leaf(i),idelay)=uold(ind_leaf(i),idelay)*damp_factor
        end do
     endif

#ifdef RT
     if(neq_chem) then
        ! Update ionization fraction
        do ii=0,nIons-1
           do i=1,nleaf
              uold(ind_leaf(i),iIons+ii) = xion(i,1+ii)*nH(i)
           end do
        end do
     endif
     if(rt) then
        ! Update photon densities and flux magnitudes
        do ig=1,nGroups
           do i=1,nleaf
              rtuold(ind_leaf(i),iGroups(ig)) = (Np(i,ig)-Np_boost(i,ig)) /scale_Np
              rtuold(ind_leaf(i),iGroups(ig)) = &
                   max(rtuold(ind_leaf(i),iGroups(ig)),smallNp)
              rtuold(ind_leaf(i),iGroups(ig)+1:iGroups(ig)+ndim)         &
                               = (Fp(i,ig,1:ndim)-Fp_boost(i,ig,1:ndim)) /scale_Fp
           enddo
        end do
     endif

     ! Split IR photons into trapped and freeflowing
     if(rt_isIRtrap) then
        if(nener .le. 0) then
           print*,'Trying to store E_trapped pressure, but NERAD too small!!'
           STOP
        endif
        iNp=iGroups(iIR)
        unit_tau = 1.5d0 * dx_loc * scale_d * scale_l
        do i=1,nleaf                                                    
           il=ind_leaf(i)                                               
           NIRtot =max(rtuold(il,iNp),smallNp)      ! Total photon density
           kScIR  = kappaSc(iIR)                                          
           if(is_kIR_T) then                        !    k_IR depends on T
              EIR = group_egy(iIR) * ev_to_erg * NIRtot *scale_Np  
              TR = max(T2_min_fix,(EIR*rt_c_cgs/c_cgs/a_r)**0.25)
              kScIR  = kappaSc(iIR) * (TR/10d0)**2               
           endif                                                        
           tau=nH(i) * Zsolar(i) * unit_tau * kScIR                    
           f_trap = exp(-1d0/tau)            ! Frac. of trapped IR photons
           f_trap = min(max(f_trap, 0d0), 1d0)                             
           ! Update freeflowing photon density, trapped photon density,
           ! and total energy density:
           rtuold(il,iNp) = max(smallnp,(1d0-f_trap) * NIRtot) ! Streaming
           EIR_trapped = f_trap * NIRtot * Np2Ep    ! Trapped phot density
           ! Update total energy due to change in trapped photon energy:
           uold(il,ndim+2)=uold(il,ndim+2)-uold(il,iIRtrapVar)+EIR_trapped
           ! Update the trapped photon energy:
           uold(il,iIRtrapVar) = EIR_trapped

           call reduce_flux(rtuold(il,iNp+1:iNp+ndim),rtuold(il,iNp)*rt_c)
        end do ! i=1,nleaf                                                 

     endif  !rt_isIRtrap     

#endif

  end do
  ! End loop over cells

end subroutine coolfine1

!************************************************************************
subroutine cmp_Eddington_tensor(Npc,Fp,T_Edd)
  
! Compute Eddington tensor for given radiation variables
! Npc     => Photon number density times light speed
! Fp     => Photon number flux
! T_Edd  <= Returned Eddington tensor
!------------------------------------------------------------------------
  use amr_commons
  implicit none
  real(dp)::Npc
  real(dp),dimension(1:ndim)::Fp ,u
  real(dp),dimension(1:ndim,1:ndim)::T_Edd 
  real(dp)::iterm,oterm,Np_c_sq,Fp_sq,fred_sq,chi
  integer::p,q
!------------------------------------------------------------------------
  if(Npc .le. 0.d0) then
     write(*,*)'negative photon density in cmp_Eddington_tensor. -EXITING-'
     call clean_stop
  endif
  T_Edd(:,:) = 0.d0   
  Np_c_sq = Npc**2        
  Fp_sq = sum(Fp**2)              !  Sq. photon flux magnitude
  u(:) = 0.d0                           !           Flux unit vector
  if(Fp_sq .gt. 0.d0) u(:) = Fp/sqrt(Fp_sq)  
  fred_sq = Fp_sq/Np_c_sq           !      Reduced flux, squared
  chi = max(4.d0-3.d0*fred_sq, 0.d0)   !           Eddington factor
  chi = (3.d0+ 4.d0*fred_sq)/(5.d0 + 2.d0*sqrt(chi))
  iterm = (1.d0-chi)/2.d0               !    Identity term in tensor
  oterm = (3.d0*chi-1.d0)/2.d0          !         Outer product term
  do p = 1, ndim
     do q = 1, ndim
        T_Edd(p,q) = oterm * u(p) * u(q)
     enddo
     T_Edd(p,p) = T_Edd(p,p) + iterm
  enddo
  
end subroutine cmp_Eddington_tensor
