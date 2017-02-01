! Non-equlibrium (in H and He) cooling module for radiation-hydrodynamics.
! For details, see Rosdahl et al. 2013, and Rosdahl & Teyssier 2015.
! Joki Rosdahl, Andreas Bleuler, and Romain Teyssier, September 2015.

module rt_cooling_module
  use amr_commons,only:myid  
  use cooling_module,only:X, Y
  use rt_parameters
  use coolrates_module
  implicit none

  private   ! default

  public rt_set_model, rt_solve_cooling, update_UVrates, cmp_chem_eq     &
         , isHe, is_mu_H2, X, Y, rhoc, kB, mH, T2_min_fix, twopi         &
         , signc, sigec, PHrate, UVrates, rt_isIR, kappaAbs, kappaSc     &
         , is_kIR_T, iIR, rt_isIRtrap, iIRtrapVar, rt_pressBoost         &
         , rt_isoPress, rt_T_rad, rt_vc, a_r

  ! NOTE: T2=T/mu
  ! Np = photon density, Fp = photon flux, 

  real(dp),parameter::rhoc      = 1.88000d-29    !  Crit. density [g cm-3]
  real(dp),parameter::mH        = 1.66000d-24    !         H atom mass [g]
  real(dp),parameter::kB        = 1.38062d-16    ! Boltzm.const. [erg K-1]
  real(dp),parameter::a_r       = 7.5657d-15   ! Rad.const. [erg cm-3 K-4]
  real(dp),parameter::mu_mol    = 1.2195D0
  real(dp),parameter::T2_min_fix=1.d-2           !     Min temperature [K]
  real(dp),parameter::twopi     = 6.2831853d0    !            Two times pi

  real(dp)::T_min, T_frac, x_min, x_frac, Np_min, Np_frac, Fp_min, Fp_frac

  integer,parameter::iIR=1                       !          IR group index
  integer::iIRtrapVar=1                          ! Trapped IR energy index
  ! Namelist parameters:
  logical::isHe=.true.
  logical::is_mu_H2=.false.
  logical::rt_isoPress=.false.         ! Use cE, not F, for rad. pressure
  real(dp)::rt_pressBoost=1d0          ! Boost on RT pressure            
  logical::rt_isIR=.false.             ! Using IR scattering on dust?    
  logical::rt_isIRtrap=.false.         ! IR trapping in NENER variable?  
  logical::is_kIR_T=.false.            ! k_IR propto T^2?               
  logical::rt_T_rad=.false.            ! Use T_gas = T_rad
  logical::rt_vc=.false.               ! (semi-) relativistic RT
  real(dp)::Tmu_dissoc=1d3             ! Dissociation temperature [K]
  real(dp),dimension(nGroups)::kappaAbs=0! Dust absorption opacity    
  real(dp),dimension(nGroups)::kappaSc=0 ! Dust scattering opacity    
  
  ! Cooling constants, updated on SED and c-change [cm3 s-1],[erg cm3 s-1]
  real(dp),dimension(nGroups,nIons)::signc,sigec,PHrate

  real(dp),dimension(nIons, 2)::UVrates     !UV backgr. heating/ion. rates

CONTAINS 

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_set_model(Nmodel, J0in_in, J0min_in, alpha_in              &
     ,normfacJ0_in, zreioniz_in, correct_cooling, realistic_ne, h        &
     ,omegab, omega0, omegaL, astart_sim, T2_sim)
! Initialize cooling. All these parameters are unused at the moment and
! are only there for the original cooling-module.
! Nmodel(integer)     =>     Model for UV background and metals
! J0in_in  (dble)     => Default UV intensity
! J0min_in (dble)     => Minimum UV intensity
! alpha_in (dble)     => Slope of the UV spectrum
! zreioniz_in (dble)  => Reionization redshift
! normfacJ0_in (dble) => Normalization factor fot a Harrdt&Madau UV model
! correct_cooling (integer) => Cooling correction
! realistic_ne (integer) => Use realistic electron density at high z?
! h (dble)            => H0/100
! omegab (dble)       => Omega baryons
! omega0 (dble)       => Omega materal total
! omegaL (dble)       => Omega Lambda
! astart_sim (dble)   => Redshift at which we start the simulation
! T2_sim (dble)      <=  Starting temperature in simulation?
!-------------------------------------------------------------------------
  use UV_module
  use coolrates_module,only: init_coolrates_tables
  real(kind=8) :: J0in_in, zreioniz_in, J0min_in, alpha_in, normfacJ0_in
  real(kind=8) :: astart_sim, T2_sim, h, omegab, omega0, omegaL
  integer  :: Nmodel, correct_cooling, realistic_ne, ig
  real(kind=8) :: astart=0.0001, aend, dasura, T2end=T2_min_fix, mu, ne
!-------------------------------------------------------------------------
  if(myid==1) write(*,*) &
       '==================RT momentum pressure is turned ON=============='
  if(myid==1 .and. rt_isIR) &
       write(*,*) 'There is an IR group, with index ',iIR        
  if(myid==1 .and. rt_isIRtrap) write(*,*) &
       '=========IR trapping is turned ON=============='
  ! do initialization
  isHe=.true. ; if(Y .le. 0.) isHe=.false.
  T_MIN           = 0.1                  !                      Minimum T2
  T_FRAC          = 0.1            

  x_MIN           = 1.d-6                !    Minimum ionization fractions
  x_FRAC          = 0.1    

  Np_MIN = 1.d-13                        !            Photon density floor
  Np_FRAC = 0.2    

  Fp_MIN  = 1D-13*rt_c_cgs               !           Minimum photon fluxes
  Fp_FRAC = 0.5

  ! Calculate initial temperature
  if (astart_sim < astart) then
     write(*,*) 'ERROR in set_model : astart_sim is too small.'
     write(*,*) 'astart     =',astart
     write(*,*) 'astart_sim =',astart_sim
     STOP
  endif
  aend=astart_sim
  dasura=0.02d0

  call update_rt_c
  call init_UV_background
  if(cosmo) then
     call update_UVrates(aexp)
     call init_coolrates_tables(aexp)
  else
     call update_UVrates(astart_sim)
     call init_coolrates_tables(astart_sim)
  endif

  if(nrestart==0 .and. cosmo)                                            &
       call rt_evol_single_cell(astart,aend,dasura,h,omegab,omega0       &
                               ,omegaL,-1.0d0,T2end,mu,ne,.false.)
  T2_sim=T2end

END SUBROUTINE rt_set_model

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE update_UVrates(aexp)
! Set the UV ionization and heating rates according to the given a_exp.
!-------------------------------------------------------------------------
  use UV_module
  use amr_parameters,only:haardt_madau
  integer::i
  real(dp)::aexp
!------------------------------------------------------------------------
  UVrates=0.
  if(.not. haardt_madau) RETURN
  
  call inp_UV_rates_table(1./aexp - 1., UVrates, .true.)

  !if(myid==1) then
  !   write(*,*) 'The UV rates have changed to:'
  !   do i=1,nIons
  !      write(*,910) UVrates(i,:)
  !   enddo
  !endif
910 format (1pe21.6, ' s-1', 1pe21.6,' erg s-1')

END SUBROUTINE update_UVrates

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_solve_cooling(T2, xion, Np, Fp, p_gas, dNpdt, dFpdt        &
                           ,nH, c_switch, Zsolar, dt, a_exp, nCell)
! Semi-implicitly solve for new temperature, ionization states, 
! photon density/flux, and gas velocity in a number of cells.
! Parameters: 
! T2     <=> T/mu [K] 
! xion   <=> NION ionization fractions 
! Np     <=> NGROUPS photon number densities [cm-3]
! Fp     <=> NGROUPS * ndim photon number fluxes [cm-2 s-1]
! p_gas  <=> ndim gas momentum densities [cm s-1 g cm-3]
! dNpdt   =>  Op split increment in photon densities during dt
! dFpdt   =>  Op split increment in photon flux magnitudes during dt
! nH      =>  Hydrogen number densities [cm-3]
! c_switch=>  Cooling switch (1 for cool/heat, 0 for no cool/heat)
! Zsolar  =>  Cell metallicities [solar fraction]
! dt      =>  Timestep size             [s]
! a_exp   =>  Cosmic expansion
! nCell   =>  Number of cells (length of all the above vectors)
!
! We use a slightly modified method of Anninos et al. (1997).
!-------------------------------------------------------------------------
  use amr_commons
  implicit none  
  real(dp),dimension(1:nvector):: T2
  real(dp),dimension(1:nIons, 1:nvector):: xion
  real(dp),dimension(1:nGroups, 1:nvector):: Np, dNpdt
  real(dp),dimension(1:ndim, 1:nGroups, 1:nvector):: Fp, dFpdt
  real(dp),dimension(1:ndim, 1:nvector):: p_gas
  real(dp),dimension(1:nvector):: nH, Zsolar
  logical,dimension(1:nvector):: c_switch
  real(dp)::dt, a_exp
  integer::ncell !--------------------------------------------------------
  real(dp),dimension(1:nvector):: tLeft, ddt
  logical:: dt_ok
  real(dp)::dt_rec
  real(dp):: dT2
  real(dp),dimension(nIons):: dXion
  real(dp),dimension(nGroups):: dNp
  real(dp),dimension(1:ndim, 1:nGroups):: dFp
  real(dp),dimension(1:ndim):: dp_gas
  integer::i, ia, ig,  nAct, nAct_next, loopcnt, code
  integer,dimension(1:nvector):: indAct              ! Active cell indexes
  real(dp)::one_over_rt_c_cgs, one_over_egy_IR_erg, one_over_x_FRAC
  real(dp)::one_over_Np_FRAC, one_over_Fp_FRAC, one_over_T_FRAC
  real(dp),dimension(1:nGroups) :: group_egy_ratio, group_egy_erg

  ! Store some temporary variables reduce computations
  one_over_rt_c_cgs = 1d0 / rt_c_cgs
  one_over_Np_FRAC = 1d0 / Np_FRAC
  one_over_Fp_FRAC = 1d0 / Fp_FRAC
  one_over_T_FRAC = 1d0 / T_FRAC
  one_over_x_FRAC = 1d0 / x_FRAC
#if NGROUPS>0 
  if(rt .and. nGroups .gt. 0) then 
     group_egy_erg(1:nGroups) = group_egy(1:nGroups) * ev_to_erg
     if(rt_isIR) then
        group_egy_ratio(1:nGroups) = group_egy(1:nGroups) / group_egy(iIR)
        one_over_egy_IR_erg = 1.d0 / group_egy_erg(iIR)
     endif
  endif
#endif
  !-----------------------------------------------------------------------
  tleft(1:ncell) = dt                !       Time left in dt for each cell
  ddt(1:ncell) = dt                  ! First guess at sub-timestep lengths

  do i=1,ncell
     indact(i) = i                   !      Set up indexes of active cells
     ! Ensure all state vars are legal:
     T2(i) = MAX(T2(i), T2_min_fix)
     xion(1:nIons,i) = MIN(MAX(xion(1:nIons,i), x_MIN),1.d0)
     if(xion(2,i)+xion(3,i) .gt. 1.d0) then
        if(xion(2,i) .gt. xion(3,i)) then
           xion(2,i)=1.d0-xion(3,i)
        else
           xion(3,i)=1.d0-xion(2,i)
        endif
     endif
     if(rt) then
        do ig=1,ngroups
           Np(ig,i) = MAX(smallNp, Np(ig,i))
           call reduce_flux(Fp(:,ig,i),Np(ig,i)*rt_c_cgs)
        end do
     endif
  end do

  ! Loop until all cells have tleft=0
  ! **********************************************
  nAct=nCell                                      ! Currently active cells
  loopcnt=0 ; n_cool_cells=n_cool_cells+nCell     !             Statistics
  do while (nAct .gt. 0)      ! Iterate while there are still active cells
     loopcnt=loopcnt+1   ;   tot_cool_loopcnt=tot_cool_loopcnt+nAct 
     nAct_next=0                     ! Active cells for the next iteration
     do ia=1,nAct                             ! Loop over the active cells
        i = indAct(ia)                        !                 Cell index
        call cool_step(i)
        if(loopcnt .gt. 100000) then
           call display_coolinfo(.true., loopcnt, i, dt-tleft(i), dt     &
                            ,ddt(i), nH(i), T2(i),  xion(:,i),  Np(:,i)  &
                            ,Fp(:,:,i),  p_gas(:,i)                      &
                            ,dT2, dXion, dNp, dFp, dp_gas, code)
        endif
        if(.not. dt_ok) then
           ddt(i)=ddt(i)/2.                    ! Try again with smaller dt 
           nAct_next=nAct_next+1 ; indAct(nAct_next) = i
           loopCodes(code) = loopCodes(code)+1
           cycle 
        endif
        ! Update the cell state (advance the time by ddt):
        T2(i)     = T2(i) + dT2
        xion(:,i) = xion(:,i) + dXion(:)
        if(nGroups .gt. 0) then 
           Np(:,i)   = Np(:,i) + dNp(:)
           Fp(:,:,i) = Fp(:,:,i) + dFp(:,:)
        endif
        p_gas(:,i)   = p_gas(:,i) + dp_gas(:)

        tleft(i)=tleft(i)-ddt(i)
        if(tleft(i) .gt. 0.) then           ! Not finished with this cell
           nAct_next=nAct_next+1 ; indAct(nAct_next) = i
        else if(tleft(i) .lt. 0.) then        ! Overshot by abs(tleft(i))
           print*,'In rt_solve_cooling: tleft < 0  !!'
           stop
        endif
        ddt(i)=min(dt_rec,tleft(i))    ! Use recommended dt from cool_step
     end do ! end loop over active cells
     nAct=nAct_next
  end do ! end iterative loop
  ! loop statistics
  max_cool_loopcnt=max(max_cool_loopcnt,loopcnt)
contains
  
  !XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
  SUBROUTINE cool_step(icell)
  ! Compute change in cell state in timestep ddt(icell), or set in dt_rec
  ! a recommendation for new timestep if ddt(icell) proves too large.
  ! T2      => T/mu [K]                                -- dT2 is new value
  ! xion    => NION ionization fractions               --     dXion is new
  ! Np      => NGROUPS photon number densities [cm-3]  -- dNp is new value
  ! Fp      => NGROUPS * ndim photon fluxes [cm-2 s-1] -- dFp is new value 
  ! p_gas   => ndim gas momenta [cm s-1 g cm-3]        --    dp_gas is new
  ! dNpdt   =>  Op split increment in photon densities during dt
  ! dFpdt   =>  Op split increment in photon flux magnitudes during dt
  ! nH      =>  Hydrogen number densities [cm-3]  
  ! c_switch=>  Cooling switch (1 for cool/heat, 0 for no cool/heat)
  ! Zsolar  =>  Cell metallicities [solar fraction]
  ! dt      =>  Timestep size [s]
  ! a_exp   =>  Cosmic expansion
  ! dt_ok   <=  .f. if timestep constraints were broken, .t. otherwise
  ! dt_rec  <=  Recommended timesteps for next iteration
  ! code    <= Error code in cool step, if dt_ok=.f.
  !
  ! The original values, T2, xion etc, must stay unchanged, while dT2,
  ! dxion etc contain the new values (the difference at the end of the
  ! routine).
  !-----------------------------------------------------------------------
    use amr_commons
    use const
    implicit none  
    integer, intent(in)::icell
    real(dp),dimension(nDim),save:: dmom
    real(dp),dimension(nDim), save:: u_gas ! Gas velocity
    real(dp),dimension(nIons),save:: alpha, beta, nN, nI
    real(dp),save:: dUU, fracMax
    real(dp),save:: xHeI, mu, TK, nHe, ne, neInit, Hrate, dAlpha, dBeta
    real(dp),save:: s, jac, q, Crate, dCdT2, X_nHkb, rate, dRate, cr, de
    real(dp),save:: photoRate, metal_tot,metal_prime, ss_factor
    integer,save:: iion,igroup,idim
    real(dp),dimension(nGroups),save:: recRad, phAbs, phSc, dustAbs
    real(dp),dimension(nGroups),save:: dustSc, kAbs_loc,kSc_loc
    real(dp),save:: rho, TR, one_over_C_v, E_rad, dE_T, fluxMag, mom_fact
    !---------------------------------------------------------------------
    dt_ok=.false.
    nHe=0.25*nH(icell)*Y/X  !         Helium number density
    ! U contains the original values, dU the updated ones:
    dT2=T2(icell) ; dXion(:)=xion(:,icell) ; dNp(:)=Np(:,icell)
    dFp(:,:)=Fp(:,:,icell) ; dp_gas(:)=p_gas(:,icell)
    ! xHI = MAX(1.-dXion(1),0.) ; xHII = dXion(1)
    ! xHeII=dXion(2) ; xHeIII=dXion(3)
    xHeI=MAX(1.-dXion(2)-dXion(3),0.d0)
    ! nN='neutral' species (pre-ionized), nI=their ionized counterparts
    nN(1)  = nH(icell) * (1.d0-dXion(1))                         !     nHI
    nN(2)  = nHe*xHeI                                            !    nHeI
    nN(3)  = nHe*dXion(2)                                        !   nHeII
    nI(1)  = nH(icell) *dXion(1)                                 !    nHII
    nI(2)  = nN(3)                                               !   nHeII
    nI(3)  = nHe*dXion(3)                                        !  nHeIII
    mu = getMu(dXion(1), dXion(2), dXion(3), dT2)
    TK = dT2 * mu                                           !  Temperature
    if(rt_isTconst) TK=rt_Tconst                       !  Force constant T
    ne= nH(icell)*dXion(1)+nHE*(dXion(2)+2.*dXion(3))  !  Electron density
    neInit=ne
    fracMax=0d0   ! Max fractional update, to check if dt can be increased
    ss_factor=1d0                    ! UV background self_shielding factor
    if(self_shielding) ss_factor = exp(-nH(icell)/1d-2)

    rho = nH(icell) / X * mH
#if NGROUPS>0 
    ! Set dust opacities--------------------------------------------------
    if(rt .and. nGroups .gt. 0) then
       kAbs_loc = kappaAbs
       kSc_loc  = kappaSc
       if(is_kIR_T) then ! k_IR depends on T
          ! Special stuff for Krumholz/Davis experiment
          if(rt_T_rad) then  ! Use radiation temperature for kappa
             E_rad = group_egy_erg(iIR) * dNp(iIR)
             TR = max(T2_min_fix,(E_rad*rt_c_fraction/a_r)**0.25)
             dT2 = TR/mu ;   TK = TR
          endif
          kAbs_loc(iIR) = kappaAbs(iIR) * (TK/10d0)**2
          kSc_loc(iIR)  = kappaSc(iIR)  * (TK/10d0)**2
       endif
       ! Set dust absorption and scattering rates [s-1]:
       dustAbs(:)  = kAbs_loc(:) *rho*Zsolar(icell)*rt_c_cgs
       dustSc(iIR) = kSc_loc(iIR)*rho*Zsolar(icell)*rt_c_cgs
    endif

    !(i) UPDATE PHOTON DENSITY AND FLUX **********************************
    if(rt .and. rt_advect) then 
       recRad(1:nGroups)=0. ; phAbs(1:nGroups)=0.              
       ! Scattering rate; reduce the photon flux, but not photon density:
       phSc(1:nGroups)=0.

       ! EMISSION FROM GAS
       if(.not. rt_OTSA .and. rt_advect) then ! ----------- Rec. radiation
          alpha(1) = inp_coolrates_table(tbl_alphaA_HII, TK) &
                   - inp_coolrates_table(tbl_alphaB_HII, TK)
          ! alpha(2) A-B becomes negative around 1K, hence the max
          alpha(2) = MAX(0.d0,  inp_coolrates_table(tbl_alphaA_HeII, TK) &
                              - inp_coolrates_table(tbl_alphaB_HeII, TK))
          alpha(3) = inp_coolrates_table(tbl_alphaA_HeIII, TK) &
                   - inp_coolrates_table(tbl_alphaB_HeIII, TK)
          do iion=1,nIons
             if(spec2group(iion) .gt. 0) &  ! Contribution of ion -> group
                  recRad(spec2group(iion)) = &
                  recRad(spec2group(iion)) + alpha(iion) * nI(iion) * ne
          enddo
       endif

       ! ABSORPTION/SCATTERING OF PHOTONS BY GAS
       do igroup=1,nGroups      ! -------------------Ionization absorbtion
          phAbs(igroup) = SUM(nN(:)*signc(igroup,:)) ! s-1
       end do
       ! IR, optical and UV depletion by dust absorption: ----------------
       if(rt_isIR) & !IR scattering/abs on dust (abs after T update)        
            phSc(iIR)  = phSc(iIR) + dustSc(iIR)                        
       do igroup=1,nGroups        ! Deplete photons, since they go into IR
          if( .not. (rt_isIR .and. igroup.eq.iIR) ) &  ! IR done elsewhere
               phAbs(igroup) = phAbs(igroup) + dustAbs(igroup)
       end do

       dmom(1:nDim)=0d0
       do igroup=1,nGroups  ! ------------------- Do the update of N and F
          dNp(igroup)= MAX(smallNp,                                      &
                        (ddt(icell)*(recRad(igroup)+dNpdt(igroup,icell)) &
                                    +dNp(igroup))                        &
                        / (1.d0+ddt(icell)*phAbs(igroup)))

          dUU = ABS(dNp(igroup)-Np(igroup,icell))                        &
                /(Np(igroup,icell)+Np_MIN) * one_over_Np_FRAC
          if(dUU .gt. 1.d0) then
             code=1 ;   RETURN                        ! ddt(icell) too big
          endif
          fracMax=MAX(fracMax,dUU)      ! To check if ddt can be increased

          do idim=1,nDim
             dFp(idim,igroup) = &
                  (ddt(icell)*dFpdt(idim,igroup,icell)+dFp(idim,igroup)) &
                  /(1d0+ddt(icell)*(phAbs(igroup)+phSc(igroup)))
          end do
          call reduce_flux(dFp(:,igroup),dNp(igroup)*rt_c_cgs)

          do idim=1,nDim
             dUU = ABS(dFp(idim,igroup)-Fp(idim,igroup,icell))           &
                  / (ABS(Fp(idim,igroup,icell))+Fp_MIN) * one_over_Fp_FRAC
             if(dUU .gt. 1.d0) then
                code=2 ;   RETURN                     ! ddt(icell) too big
             endif
             fracMax=MAX(fracMax,dUU)   ! To check if ddt can be increased
          end do

       end do

       do igroup=1,nGroups ! -------Momentum transfer from photons to gas:
          mom_fact = ddt(icell) * (phAbs(igroup) + phSc(igroup)) &
               * group_egy_erg(igroup) * one_over_c_cgs

          if(rt_isoPress .and. .not. (rt_isIR .and. igroup==iIR)) then 
             ! rt_isoPress: assume f=1, where f is reduced flux.
             fluxMag=sqrt(sum((dFp(:,igroup))**2))
             if(fluxMag .gt. 0d0) then
                mom_fact = mom_fact * dNp(igroup) / fluxMag
             else
                mom_fact = 0d0
             endif
          else
             mom_fact = mom_fact * one_over_rt_c_cgs 
          end if

          do idim = 1, nDim
             dmom(idim) = dmom(idim) + dFp(idim,igroup) * mom_fact
          end do
       end do
       dp_gas = dp_gas + dmom * rt_pressBoost        ! update gas momentum

       ! Add absorbed UV/optical energy to IR:----------------------------  
       if(rt_isIR) then   
          do igroup=iIR+1,nGroups
             dNp(iIR) = dNp(iIR) + dustAbs(igroup) * ddt(icell)          &
                  * dNp(igroup) * group_egy_ratio(igroup)
          end do
       endif
       ! -----------------------------------------------------------------
    endif !if(rt)
#endif
    !(ii) UPDATE TEMPERATURE *********************************************
    if(c_switch(icell) .and. cooling .and. .not. rt_T_rad) then
       Hrate=0.                             !  Heating rate [erg cm-3 s-1]
       if(rt .and. rt_advect) then
          do igroup=1,nGroups                              !  Photoheating
             Hrate = Hrate + dNp(igroup) * SUM(nN(:) * PHrate(igroup,:))
          end do
       endif
       if(haardt_madau) Hrate= Hrate + SUM(nN(:)*UVrates(:,2)) * ss_factor
       Crate = compCoolrate(TK, ne, nN(1), nI(1), nN(2), nN(3), nI(3)    &
            ,a_exp, dCdT2, RT_OTSA)                  ! Cooling
       dCdT2 = dCdT2 * mu                            ! dC/dT2 = mu * dC/dT
       metal_tot=0.d0 ; metal_prime=0.d0             ! Metal cooling
       if(Zsolar(icell) .gt. 0d0) &
            call rt_cmp_metals(T2(icell),nH(icell),mu,metal_tot          &
                              ,metal_prime,a_exp)
       X_nHkb= X/(1.5 * nH(icell) * kB)            ! Multiplication factor   
       rate  = X_nHkb*(Hrate - Crate - Zsolar(icell)*metal_tot)
       dRate = -X_nHkb*(dCdT2 + Zsolar(icell)*metal_prime)     ! dRate/dT2
       ! 1st order dt constr
       dUU   = ABS(MAX(T2_min_fix, T2(icell)+rate*ddt(icell))-T2(icell))
       ! New T2 value 
       dT2   = MAX(T2_min_fix &
                  ,T2(icell)+rate*ddt(icell)/(1.-dRate*ddt(icell)))
       dUU   = MAX(dUU, ABS(dT2-T2(icell))) / (T2(icell)+T_MIN) &
                        *one_over_T_FRAC
       if(dUU .gt. 1.) then                                     ! 10% rule
          code=3 ; RETURN
       endif
       fracMax=MAX(fracMax,dUU)
       TK=dT2*mu
    endif

#if NGROUPS>0 
    if(rt_isIR) then
       if(kAbs_loc(iIR) .gt. 0d0 .and. .not. rt_T_rad) then
          ! Evolve IR-Dust equilibrium temperature------------------------
          ! Delta (Cv T)= ( c_red/lambda E - c/lambda a T^4) 
          !           / ( 1/Delta t + 4 c/lambda/C_v a T^3 + c_red/lambda)
          one_over_C_v = mh*mu*(gamma-1d0) / (rho*kb)
          E_rad = group_egy_erg(iIR) * dNp(iIR)
          dE_T = (rt_c_cgs * E_rad - c_cgs*a_r*TK**4)                    &
               /(1d0/(kAbs_loc(iIR) * Zsolar(icell) * rho * ddt(icell))  &
               +4d0*c_cgs * one_over_C_v *a_r*TK**3+rt_c_cgs)
          dT2 = dT2 + 1d0/mu * one_over_C_v * dE_T
          dNp(iIR) = dNp(iIR) - dE_T * one_over_egy_IR_erg

          dT2 = max(T2_min_fix,dT2)                                   
          dNp(iIR) = max(dNp(iIR), smallNp)
          ! 10% rule for photon density:
          dUU = ABS(dNp(iIR)-Np(iIR,icell)) / (Np(iIR,icell)+Np_MIN)     &
                                            * one_over_Np_FRAC
          if(dUU .gt. 1.) then                 
             code=4 ;   RETURN                          
          endif
          fracMax=MAX(fracMax,dUU)                                           

          dUU   = ABS(dT2-T2(icell)) / (T2(icell)+T_MIN) * one_over_T_FRAC
          if(dUU .gt. 1.) then                           ! 10% rule for T2
             code=5 ; RETURN                                                  
          endif
          fracMax=MAX(fracMax,dUU)
          TK=dT2*mu
          call reduce_flux(dFp(:,iIR),dNp(iIR)*rt_c_cgs)           
       endif
    endif
#endif
    !(iii) UPDATE xHII****************************************************
    ! First recompute interaction rates since T is updated
    if(rt_OTSA .or. .not. rt_advect) then           !  Recombination rates
       alpha(1) = inp_coolrates_table(tbl_alphaB_HII, TK, dalpha)
    else                               
       alpha(1) = inp_coolrates_table(tbl_alphaA_HII, TK, dalpha)
    endif
    beta(1) = inp_coolrates_table(tbl_beta_HI, TK, dBeta) !  Coll-ion rate
    cr = beta(1) * ne                             !               Creation
    if(rt) cr = cr + SUM(signc(:,1)*dNp)          !                  [s-1]
    if(haardt_madau) cr = cr + UVrates(1,1) * ss_factor
    de = alpha(1) * ne                            !            Destruction

    ! Not Anninos, but more stable (this IS neccessary, as the one-cell  !
    ! tests oscillate wildly in the Anninos method):                     !
    S  = cr*(1.-dXion(1))-de*dXion(1)
    dUU= ABS(MIN(MAX(dXion(1)+ddt(icell)*S, x_MIN), 1.)-dXion(1))
    jac=(1.-dXion(1))*(beta(1)*nH(icell)-ne*TK*mu*X*dBeta) & !jac=dS/dxHII
         - cr - de - dXion(1) * (alpha(1)*nH(icell)-ne*TK*mu*X*dAlpha)
    dXion(1) = xion(1,icell)                                             &
             + ddt(icell)*(cr*(1.-xion(1,icell))-de*xion(1,icell))       &
             / (1.-ddt(icell)*jac)
    dXion(1) = MIN(MAX(dXion(1), x_MIN),1.d0)
    dUU = MAX(dUU, ABS(dXion(1)-xion(1,icell))) / (xion(1,icell)+x_MIN)  &
                                                * one_over_x_FRAC
    if(dUU .gt. 1.) then
       code=6 ; RETURN
    endif
    fracMax=MAX(fracMax,dUU)
    !End a more stable and accurate integration---------------------------
    if(isHe) then
       ne= nH(icell)*dXion(1)+nHE*(dXion(2)+2.*dXion(3)) ! Bc changed xhii
       mu = getMu(dXion(1), dXion(2), dXion(3), dT2)
       if(.not. rt_isTconst) TK=dT2*mu !  Update TK because of changed  mu

       !(iv) UPDATE xHeI *************************************************
       if(rt_OTSA .or. .not. rt_advect) then
          alpha(2) = inp_coolrates_table(tbl_alphaB_HeII, TK)
          alpha(3) = inp_coolrates_table(tbl_alphaB_HeIII, TK)
       else                               
          alpha(2) = inp_coolrates_table(tbl_alphaA_HeII, TK)
          alpha(3) = inp_coolrates_table(tbl_alphaA_HeIII, TK)
       endif
       beta(2) =  inp_coolrates_table(tbl_beta_HeI, TK)
       beta(3) = inp_coolrates_table(tbl_beta_HeII, TK)
       ! Creation = recombination of HeII and electrons
       cr = alpha(2) * ne * dXion(2)
       ! Destruction = collisional ionization+photoionization of HeI
       de = beta(2) * ne
       if(rt) de = de + SUM(signc(:,2)*dNp)
       if(haardt_madau) de = de + UVrates(2,1) * ss_factor
       xHeI = (cr*ddt(icell)+xHeI)/(1.+de*ddt(icell))        !  The update
       xHeI = MIN(MAX(xHeI, 0.),1.)

       !(v) UPDATE xHeII *************************************************
       ! Creation = coll.- and photo-ionization of HI + rec. of HeIII
       cr = de * xHeI + alpha(3) * ne * dXion(3)
       ! Destruction = rec. of HeII + coll.- and photo-ionization of HeII
       photoRate=0.
       if(rt) photoRate = SUM(signc(:,3)*dNp)
       if(haardt_madau) photoRate = photoRate + UVrates(3,1) * ss_factor
       de = (alpha(2) + beta(3)) * ne + photoRate
       dXion(2) = (cr*ddt(icell)+dXion(2))/(1.+de*ddt(icell)) ! The update
       dXion(2) = MIN(MAX(dXion(2), x_MIN),1.)

       !(vii) UPDATE xHeIII **********************************************
       ! Creation = coll.- and photo-ionization of HeII
       cr = (beta(3) * ne + photoRate) * dXion(2)          !  xHeII is new
       ! Destruction = rec. of HeIII and e
       de = alpha(3) * ne
       dXion(3) = (cr*ddt(icell)+dXion(3))/(1.+de*ddt(icell)) ! The update
       dXion(3) = MIN(MAX(dXion(3), x_MIN),1.)

       !(viii) ATOMIC CONSERVATION OF He *********************************
       if(xHeI .ge. dXion(3)) then   ! Either HeI or HeII is most abundant 
          if(xHeI .le. dXion(2)) dXion(2) = 1.-xHeI-dXion(3) !HeII most ab
       else                        ! Either HeII or HeIII is most abundant 
          if(dXion(2) .le. dXion(3)) then
             dXion(3) = 1. - xHeI-dXion(2)                         ! HeIII
          else
             dXion(2) = 1. - xHeI-dXion(3)                         !  HeII
          endif
       endif
    endif

    ne = nH(icell)*dXion(1)+nHe*(dXion(2)+2.*dXion(3))
    dUU=ABS((ne-neInit)) / (neInit+x_MIN) * one_over_x_FRAC
    if(dUU .gt. 1.) then
       code=7 ; RETURN
    endif
    fracMax=MAX(fracMax,dUU)

    if(rt_isTconst) dT2=rt_Tconst/mu

    dT2 = dT2-T2(icell) ; dXion(:) = dXion(:)-xion(:,icell)
    dNp(:) = dNp(:)-Np(:,icell) ; dFp(:,:) = dFp(:,:)-Fp(:,:,icell)
    dp_gas(:)= dp_gas(:)-p_gas(:,icell)
    ! Now the dUs are really changes, not new values
    !(ix) Check if we are safe to use a bigger timestep in next iteration:
    if(fracMax .lt. 0.5) then
       dt_rec=ddt(icell)*2.
    else
       dt_rec=ddt(icell)
    endif
    dt_ok=.true.
    code=0

  END SUBROUTINE cool_step

END SUBROUTINE rt_solve_cooling

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE display_coolinfo(stopRun, loopcnt, i, dtDone, dt, ddt, nH    &
                            ,T2,  xion,  Np,  Fp,  p_gas                &
                            ,dT2, dXion, dNp, dFp, dp_gas, code)
! Print cooling information to standard output, and maybe stop execution.
!------------------------------------------------------------------------
  use amr_commons
  use rt_parameters
  real(dp),dimension(nIons):: xion, dXion
  real(dp),dimension(nGroups):: Np, dNp
  real(dp),dimension(nDim, nGroups):: Fp, dFp
  real(dp),dimension(nDim):: p_gas, dp_gas
  real(dp)::T2, dT2, dtDone, dt, ddt, nH
  logical::stopRun
  integer::loopcnt,i, code
!------------------------------------------------------------------------
  if(stopRun) write(*, 111) loopcnt
  if(.true.) then
     write(*,900) loopcnt, myid, code, i, dtDone, dt, ddt, rt_c_cgs, nH
     write(*,901) T2,      xion,      Np,      Fp,      p_gas
     write(*,902) dT2,     dXion,     dNp,     dFp,     dp_gas
     write(*,903) dT2/ddt, dXion/ddt, dNp/ddt, dFp/ddt, dp_gas/ddt
     write(*,904) abs(dT2)/(T2+T_MIN), abs(dxion)/(xion+x_MIN),          &
                  abs(dNp)/(Np+Np_MIN), abs(dFp)/(Fp+Fp_MIN)
  endif
  print*,loopcodes
  print*,group_egy(:)
  if(stopRun) then
     print *,'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
     STOP
  endif

111 format(' Stopping because of large number of timestesps in', &
           ' rt_solve_cooling (', I6, ')')
900 format (I3, '  myid=', I2, ' code=', I2, ' i=', I5, ' t=', 1pe12.3,xs&
            '/', 1pe12.3, ' ddt=', 1pe12.3, ' c=', 1pe12.3, &
            ' nH=', 1pe12.3)
901 format ('  U      =', 20(1pe12.3))
902 format ('  dU     =', 20(1pe12.3))
903 format ('  dU/dt  =', 20(1pe12.3))
904 format ('  dU/U % =', 20(1pe12.3))
END SUBROUTINE display_coolinfo

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE cmp_chem_eq(TK, nH, t_rad_spec, nSpec, nTot, mu)

! Compute chemical equilibrium abundances of e, HI, HII, HeI, HeII, HeIII
! r_rad_spec => photoionization rates [s-1] for HI, HeI, HeII
!------------------------------------------------------------------------
  implicit none
  real(dp),intent(in)::TK, nH
  real(dp),intent(out)::nTot, mu
  real(dp),dimension(1:3),intent(in)::t_rad_spec
  real(dp),dimension(1:6),intent(out)::nSpec!------------------------
  real(dp)::xx, yy
  real(dp)::n_HI, n_HII, n_HEI, n_HEII, n_HEIII, n_E
  real(dp)::t_rad_HI,  t_rad_HEI,  t_rad_HEII
  real(dp)::t_rec_HI,  t_rec_HEI,  t_rec_HEII
  real(dp)::t_ion_HI,  t_ion_HEI,  t_ion_HEII
  real(dp)::t_ion2_HI, t_ion2_HEI, t_ion2_HEII
  real(dp)::x1, err_nE
  integer,parameter::HI=1, HeI=2, HeII=3
!------------------------------------------------------------------------
  xx=(1.-Y)
  yy=Y/(1.-Y)/4.
  
  t_rad_HI   = t_rad_spec(HI)                !      Photoionization [s-1]
  t_rad_HEI  = t_rad_spec(HeI)
  t_rad_HEII = t_rad_spec(HeII)

  if(rt_OTSA) then                           !    Recombination [cm3 s-1]
     t_rec_HI   = inp_coolrates_table(tbl_alphaB_HII, TK)
     t_rec_HEI  = inp_coolrates_table(tbl_alphaB_HeII, TK)
     t_rec_HEII = inp_coolrates_table(tbl_alphaB_HeIII, TK)
  else 
     t_rec_HI   = inp_coolrates_table(tbl_alphaA_HII, TK)
     t_rec_HEI  = inp_coolrates_table(tbl_alphaA_HeII, TK)
     t_rec_HEII = inp_coolrates_table(tbl_alphaA_HeIII, TK)
  endif

  t_ion_HI   = inp_coolrates_table(tbl_beta_HI, TK) ! Coll. ion. [cm3 s-1]
  t_ion_HEI  = inp_coolrates_table(tbl_beta_HeI, TK)
  t_ion_HEII = inp_coolrates_table(tbl_beta_HeII, TK)
  
  n_E = nH        
  err_nE = 1.
  
  do while(err_nE > 1.d-8)
     t_ion2_HI   = t_ion_HI   + t_rad_HI  /MAX(n_E,1e-15*nH)  ! [cm3 s-1]
     t_ion2_HEI  = t_ion_HEI  + t_rad_HEI /MAX(n_E,1e-15*nH)
     t_ion2_HEII = t_ion_HEII + t_rad_HEII/MAX(n_E,1e-15*nH)
     
     n_HI  = t_rec_HI/(t_ion2_HI+t_rec_HI)*nH
     n_HII = t_ion2_HI/(t_ion2_HI+t_rec_HI)*nH
     
     x1=(                                                                &
          t_rec_HEII*t_rec_HEI                                           &
          +t_ion2_HEI*t_rec_HEII                                         &
          +t_ion2_HEII*t_ion2_HEI)                               ! cm6 s-2
     
     n_HEIII = yy*t_ion2_HEII*t_ion2_HEI/x1*nH
     n_HEII  = yy*t_ion2_HEI *t_rec_HEII/x1*nH
     n_HEI   = yy*t_rec_HEII *t_rec_HEI /x1*nH
     
     err_nE = ABS((n_E - (n_HII + n_HEII + 2.*n_HEIII))/nH)
     n_E = 0.5*n_E+0.5*(n_HII + n_HEII + 2.*n_HEIII)
     
  end do
    
  nTOT     = n_E+n_HI+n_HII+n_HEI+n_HEII+n_HEIII
  mu       = nH/xx/nTOT
  nSpec(1) = n_E
  nSpec(2) = n_HI
  nSpec(3) = n_HII
  nSpec(4) = n_HEI
  nSpec(5) = n_HEII
  nSpec(6) = n_HEIII
  
END SUBROUTINE cmp_chem_eq

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_evol_single_cell(astart,aend,dasura,h,omegab,omega0,omegaL &
                           ,J0min_in,T2end,mu,ne,if_write_result)
!-------------------------------------------------------------------------
! Used for initialization of thermal state in cosmological simulations.
!
! astart : valeur du facteur d'expansion au debut du calcul
! aend   : valeur du facteur d'expansion a la fin du calcul
! dasura : la valeur de da/a entre 2 pas de temps
! h      : la valeur de H0/100 
! omegab : la valeur de Omega baryons
! omega0 : la valeur de Omega matiere (total)
! omegaL : la valeur de Omega Lambda
! J0min_in : la valeur du J0min a injecter :
!          Si high_z_realistic_ne alors c'est J0min a a=astart qui
!          est considere
!          Sinon, c'est le J0min habituel.
!          Si J0min_in <=0, les parametres par defaut ou predefinis
!          auparavant sont pris pour le J0min.
! T2end  : Le T/mu en output
! mu     : le poids moleculaire en output
! ne     : le ne en output
! if_write_result : .true. pour ecrire l'evolution de la temperature
!          et de n_e sur l'ecran.
!-------------------------------------------------------------------------
  use amr_commons,only:myid
  use UV_module
  implicit none
  real(kind=8)::astart,aend,T2end,h,omegab,omega0,omegaL,J0min_in,ne,dasura
  logical :: if_write_result
  real(dp)::aexp,daexp,dt_cool,coeff,T2_com, nH_com  
  real(dp),dimension(nIons)::pHI_rates=0., h_rad_spec=0.
  real(kind=8) ::mu
  real(dp) ::cool_tot,heat_tot, mu_dp,diff
  integer::niter
  real(dp) :: n_spec(1:6)
  real(dp),dimension(1:nvector):: T2
  real(dp),dimension(1:nIons, 1:nvector):: xion
  real(dp),dimension(1:nGroups, 1:nvector):: Np, dNpdt
  real(dp),dimension(1:ndim, 1:nGroups, 1:nvector):: Fp, dFpdt
  real(dp),dimension(1:ndim, 1:nvector):: p_gas
  real(dp),dimension(1:nvector)::nH=0., Zsolar=0.
  logical,dimension(1:nvector)::c_switch=.true.
!-------------------------------------------------------------------------
  aexp = astart
  T2_com = 2.726d0 / aexp * aexp**2 / mu_mol
  nH_com = omegab*rhoc*h**2*X/mH

  mu_dp=mu
  call cmp_Equilibrium_Abundances(                                       &
                 T2_com/aexp**2, nH_com/aexp**3, pHI_rates, mu_dp, n_Spec)
  ! Initialize cell state
  T2(1)=T2_com                                          !      Temperature
  xion(1,1)=n_Spec(3)/(nH_com/aexp**3)                  !   HII   fraction
  xion(2,1)=n_Spec(5)/(nH_com/aexp**3)                  !   HeII  fraction
  xion(3,1)=n_Spec(6)/(nH_com/aexp**3)                  !   HeIII fraction
  p_gas(:,1)=0.
  Np(:,1)=0. ; Fp(:,:,1)=0.                  ! Photon densities and fluxes
  dNpdt(:,1)=0. ; dFpdt(:,:,1)=0.                              
  do while (aexp < aend)
     call update_UVrates(aexp)
     call update_coolrates_tables(aexp)
     
     daexp = dasura*aexp
     dt_cool = daexp                                                     &
             / (aexp*100.*h*3.2408608e-20)                               &
             / HsurH0(1.0/dble(aexp)-1.,omega0,omegaL,1.-omega0-omegaL)
     
     nH(1) = nH_com/aexp**3
     T2(1) = T2(1)/aexp**2
     call rt_solve_cooling(T2,xion,Np,Fp,p_gas,dNpdt,dFpdt,nH,c_switch   &
                           ,Zsolar,dt_cool,aexp,1)
     T2(1)=T2(1)*aexp**2
     aexp = aexp + daexp
     if (if_write_result) write(*,'(4(1pe10.3))')                        &
                              aexp,nH(1),T2_com*mu/aexp**2,n_spec(1)/nH(1)
  end do
  T2end=T2(1)/(aexp-daexp)**2
  ne=(n_spec(3)+(n_spec(5)+2.*n_spec(6))*0.25*Y/X)
end subroutine rt_evol_single_cell

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
FUNCTION HsurH0(z,omega0,omegaL,OmegaR)
!-------------------------------------------------------------------------
  implicit none
  real(kind=8) :: HsurH0,z,omega0,omegaL,omegaR
!-------------------------------------------------------------------------
  HsurH0=sqrt(Omega0*(1.d0+z)**3+OmegaR*(1.d0+z)**2+OmegaL)
END FUNCTION HsurH0

!=========================================================================
subroutine rt_cmp_metals(T2,nH,mu,metal_tot,metal_prime,aexp)
! Taken from the equilibrium cooling_module of RAMSES
! Compute cooling enhancement due to metals
! T2           => Temperature in Kelvin, divided by mu
! nH           => Hydrogen number density (H/cc)
! mu           => Average mass per particle in terms of mH
! metal_tot   <=  Metal cooling contribution to de/dt [erg s-1 cm-3]
! metal_prime <=  d(metal_tot)/dT2 [erg s-1 cm-3 K-1]
!=========================================================================
  implicit none
  real(dp) ::T2,nH,mu,metal_tot,metal_prime,aexp
  ! Cloudy at solar metalicity
  real(dp),dimension(1:91),parameter :: temperature_cc07 = (/ &
       & 3.9684,4.0187,4.0690,4.1194,4.1697,4.2200,4.2703, &
       & 4.3206,4.3709,4.4212,4.4716,4.5219,4.5722,4.6225, &
       & 4.6728,4.7231,4.7734,4.8238,4.8741,4.9244,4.9747, &
       & 5.0250,5.0753,5.1256,5.1760,5.2263,5.2766,5.3269, &
       & 5.3772,5.4275,5.4778,5.5282,5.5785,5.6288,5.6791, &
       & 5.7294,5.7797,5.8300,5.8804,5.9307,5.9810,6.0313, &
       & 6.0816,6.1319,6.1822,6.2326,6.2829,6.3332,6.3835, &
       & 6.4338,6.4841,6.5345,6.5848,6.6351,6.6854,6.7357, &
       & 6.7860,6.8363,6.8867,6.9370,6.9873,7.0376,7.0879, &
       & 7.1382,7.1885,7.2388,7.2892,7.3395,7.3898,7.4401, &
       & 7.4904,7.5407,7.5911,7.6414,7.6917,7.7420,7.7923, &
       & 7.8426,7.8929,7.9433,7.9936,8.0439,8.0942,8.1445, &
       & 8.1948,8.2451,8.2955,8.3458,8.3961,8.4464,8.4967 /)
  ! Cooling from metals only (without the contribution of H and He)
  ! log cooling rate in [erg s-1 cm3]
  ! S. Ploeckinger 06/2015
  real(kind=8),dimension(1:91) :: excess_cooling_cc07 = (/ &
       &  -24.9082, -24.9082, -24.5503, -24.0898, -23.5328, -23.0696, -22.7758, &
       &  -22.6175, -22.5266, -22.4379, -22.3371, -22.2289, -22.1181, -22.0078, &
       &  -21.8992, -21.7937, -21.6921, -21.5961, -21.5089, -21.4343, -21.3765, &
       &  -21.3431, -21.3274, -21.3205, -21.3142, -21.3040, -21.2900, -21.2773, &
       &  -21.2791, -21.3181, -21.4006, -21.5045, -21.6059, -21.6676, -21.6877, &
       &  -21.6934, -21.7089, -21.7307, -21.7511, -21.7618, -21.7572, -21.7532, &
       &  -21.7668, -21.7860, -21.8129, -21.8497, -21.9035, -21.9697, -22.0497, &
       &  -22.1327, -22.2220, -22.3057, -22.3850, -22.4467, -22.4939, -22.5205, &
       &  -22.5358, -22.5391, -22.5408, -22.5408, -22.5475, -22.5589, -22.5813, &
       &  -22.6122, -22.6576, -22.7137, -22.7838, -22.8583, -22.9348, -23.0006, &
       &  -23.0547, -23.0886, -23.1101, -23.1139, -23.1147, -23.1048, -23.1017, &
       &  -23.0928, -23.0969, -23.0968, -23.1105, -23.1191, -23.1388, -23.1517, &
       &  -23.1717, -23.1837, -23.1986, -23.2058, -23.2134, -23.2139, -23.2107 /)
  real(dp),dimension(1:91),parameter :: excess_prime_cc07 = (/           & 
       &   2.0037,  4.7267, 12.2283, 13.5820,  9.8755,  4.8379,  1.8046, &
       &   1.4574,  1.8086,  2.0685,  2.2012,  2.2250,  2.2060,  2.1605, &
       &   2.1121,  2.0335,  1.9254,  1.7861,  1.5357,  1.1784,  0.7628, &
       &   0.1500, -0.1401,  0.1272,  0.3884,  0.2761,  0.1707,  0.2279, &
       &  -0.2417, -1.7802, -3.0381, -2.3511, -0.9864, -0.0989,  0.1854, &
       &  -0.1282, -0.8028, -0.7363, -0.0093,  0.3132,  0.1894, -0.1526, &
       &  -0.3663, -0.3873, -0.3993, -0.6790, -1.0615, -1.4633, -1.5687, &
       &  -1.7183, -1.7313, -1.8324, -1.5909, -1.3199, -0.8634, -0.5542, &
       &  -0.1961, -0.0552,  0.0646, -0.0109, -0.0662, -0.2539, -0.3869, &
       &  -0.6379, -0.8404, -1.1662, -1.3930, -1.6136, -1.5706, -1.4266, &
       &  -1.0460, -0.7244, -0.3006, -0.1300,  0.1491,  0.0972,  0.2463, &
       &   0.0252,  0.1079, -0.1893, -0.1033, -0.3547, -0.2393, -0.4280, &
       &  -0.2735, -0.3670, -0.2033, -0.2261, -0.0821, -0.0754,  0.0634 /)
  real(dp),dimension(1:50),parameter::z_courty=(/                         &
       & 0.00000,0.04912,0.10060,0.15470,0.21140,0.27090,0.33330,0.39880, &
       & 0.46750,0.53960,0.61520,0.69450,0.77780,0.86510,0.95670,1.05300, &
       & 1.15400,1.25900,1.37000,1.48700,1.60900,1.73700,1.87100,2.01300, &
       & 2.16000,2.31600,2.47900,2.64900,2.82900,3.01700,3.21400,3.42100, &
       & 3.63800,3.86600,4.10500,4.35600,4.61900,4.89500,5.18400,5.48800, &
       & 5.80700,6.14100,6.49200,6.85900,7.24600,7.65000,8.07500,8.52100, &
       & 8.98900,9.50000 /)
  real(dp),dimension(1:50),parameter::phi_courty=(/                             &
       & 0.0499886,0.0582622,0.0678333,0.0788739,0.0915889,0.1061913,0.1229119, &
       & 0.1419961,0.1637082,0.1883230,0.2161014,0.2473183,0.2822266,0.3210551, &
       & 0.3639784,0.4111301,0.4623273,0.5172858,0.5752659,0.6351540,0.6950232, &
       & 0.7529284,0.8063160,0.8520859,0.8920522,0.9305764,0.9682031,1.0058810, &
       & 1.0444020,1.0848160,1.1282190,1.1745120,1.2226670,1.2723200,1.3231350, &
       & 1.3743020,1.4247480,1.4730590,1.5174060,1.5552610,1.5833640,1.5976390, &
       & 1.5925270,1.5613110,1.4949610,1.3813710,1.2041510,0.9403100,0.5555344, & 
       & 0.0000000 /)
  real(dp)::TT,lTT,deltaT,lcool,lcool1,lcool2,lcool1_prime,lcool2_prime
  real(dp)::ZZ,deltaZ
  real(dp)::c1=0.4,c2=10.0,TT0=1d5,TTC=1d6,alpha1=0.15
  real(dp)::ux,g_courty,f_courty=1d0,g_courty_prime,f_courty_prime
  integer::iT,iZ
!-------------------------------------------------------------------------
  ZZ=1d0/aexp-1d0
  TT=T2*mu
  lTT=log10(TT)
  ! This is a simple model to take into account the ionization background
  ! on metal cooling (calibrated using CLOUDY). 
  iZ=1+int(ZZ/z_courty(50)*49.)
  iZ=min(iZ,49)
  iZ=max(iZ,1)
  deltaZ=z_courty(iZ+1)-z_courty(iZ)
  ZZ=min(ZZ,z_courty(50))
  ux=1d-4*(phi_courty(iZ+1)*(ZZ-z_courty(iZ))/deltaZ & 
       & + phi_courty(iZ)*(z_courty(iZ+1)-ZZ)/deltaZ )/nH
  g_courty=c1*(TT/TT0)**alpha1+c2*exp(-TTC/TT)
  g_courty_prime=(c1*alpha1*(TT/TT0)**alpha1+c2*exp(-TTC/TT)*TTC/TT)/TT
  f_courty=1d0/(1d0+ux/g_courty)
  f_courty_prime=ux/g_courty/(1d0+ux/g_courty)**2*g_courty_prime/g_courty

  if(lTT.ge.temperature_cc07(91))then
     metal_tot=0d0 !1d-100
     metal_prime=0d0
  else if(lTT.ge.1.0)then
     lcool1=-100d0
     lcool1_prime=0d0
      if(lTT.ge.temperature_cc07(1))then
        iT=1+int((lTT-temperature_cc07(1)) /                             &
             (temperature_cc07(91)-temperature_cc07(1))*90.0)
        iT=min(iT,90)
        iT=max(iT,1)
        deltaT = temperature_cc07(iT+1) - temperature_cc07(iT)
        lcool1 = &
             excess_cooling_cc07(iT+1)*(lTT-temperature_cc07(iT))/deltaT &
           + excess_cooling_cc07(iT)*(temperature_cc07(iT+1)-lTT)/deltaT 
        lcool1_prime  =                                                  &
             excess_prime_cc07(iT+1)*(lTT-temperature_cc07(iT))/deltaT   &
           + excess_prime_cc07(iT)*(temperature_cc07(iT+1)-lTT)/deltaT 
     endif
     ! Fine structure cooling from infrared lines
     lcool2=-31.522879+2.0*lTT-20.0/TT-TT*4.342944d-5
     lcool2_prime=2d0+(20d0/TT-TT*4.342944d-5)*log(10d0)
     ! Total metal cooling and temperature derivative
     metal_tot=10d0**lcool1+10d0**lcool2
     metal_prime=(10d0**lcool1*lcool1_prime+10d0**lcool2*lcool2_prime)/metal_tot
     metal_prime=metal_prime*f_courty+metal_tot*f_courty_prime
     metal_tot=metal_tot*f_courty
  else
     metal_tot=0d0 !1d-100
     metal_prime=0d0
  endif

  metal_tot=metal_tot*nH**2
  metal_prime=           &   ! Convert from DlogLambda/DlogT to DLambda/DT
       metal_prime * metal_tot/TT * mu

end subroutine rt_cmp_metals

!*************************************************************************
FUNCTION getMu(xHII, xHeII, xHeIII, Tmu)
! Returns the mean particle mass, in units of the proton mass.
! xHII, xHeII, xHeIII => Hydrogen and helium ionisation fractions
! Tmu => T/mu in Kelvin  
!-------------------------------------------------------------------------
  implicit none
  real(kind=8),intent(in) :: xHII, xHeII, xHeIII, Tmu
  real(kind=8) :: mu
  real(kind=8) :: getMu
!-------------------------------------------------------------------------
  getMu = 1./(X*(1.+xHII) + 0.25*Y*(1.+xHeII+2.*xHeIII))   
  if(is_kIR_T .or. is_mu_H2) &
       getMu = getMu + exp(-1.d0*(Tmu/Tmu_dissoc)**2) * (2.33-getMu)
END FUNCTION getMu


END MODULE rt_cooling_module

!************************************************************************
SUBROUTINE updateRTGroups_CoolConstants()
! Update photon group cooling and heating constants, to reflect an update
! in rt_c_cgs and in the cross-sections and energies in the groups.
!------------------------------------------------------------------------
  use rt_cooling_module
  use rt_parameters
  implicit none
  integer::iP, iI
!------------------------------------------------------------------------
  signc=group_csn*rt_c_cgs                                    ! [cm3 s-1]
  sigec=group_cse*rt_c_cgs                                    ! [cm3 s-1]
  do iP=1,nGroups
     do iI=1,nIons               ! Photoheating rates for photons on ions
        PHrate(iP,iI) =  ev_to_erg * &        ! See eq (19) in Aubert(08)
             (sigec(iP,iI) * group_egy(iP) - signc(iP,iI)*ionEvs(iI))
        PHrate(iP,iI) = max(PHrate(iP,iI),0d0) !      No negative heating
     end do
  end do
END SUBROUTINE updateRTGroups_CoolConstants

!************************************************************************
SUBROUTINE reduce_flux(Fp, cNp)
! Make sure the reduced photon flux is less than one
!------------------------------------------------------------------------
  use rt_parameters
  implicit none
  real(dp),dimension(ndim):: Fp
  real(dp):: cNp, fred
!------------------------------------------------------------------------
  fred = sqrt(sum(Fp**2))/cNp
  if(fred .gt. 1.d0) Fp = Fp/fred
END SUBROUTINE reduce_flux


