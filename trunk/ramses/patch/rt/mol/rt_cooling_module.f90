module rt_cooling_module
  use amr_commons,only:myid  
  use cooling_module,only:X, Y
  use rt_parameters
  use coolrates_module
  implicit none

  private   ! default

  public rt_set_model, rt_solve_cooling, update_UVrates, cmp_chem_eq     &
         ,rhoc, kB, mH, T2_min_fix, twopi, n_U, iNpU, iFpU               &
         ,signc, sigec, PHrate, UVrates,X,Y

  ! U= (T2, x_1, ..., x_m, Np_1, ..., Np_n, Fp_1, ..., Fp_n), 
  ! where x=ionization fraction, m=nIons, n=nGroups.
  ! NOTE: T2=T/mu

  real(dp),parameter::rhoc      = 1.88000d-29    !  Crit. density [g cm-3]
  real(dp),parameter::mH        = 1.66000d-24    !         H atom mass [g]
  real(dp),parameter::kB        = 1.38062d-16    ! Boltzm.const. [erg K-1]
  real(dp),parameter::mu_mol    = 1.2195D0
  real(dp),parameter::T2_min_fix=1.d-2           !     Min temperature [K]
  real(dp),parameter::twopi     = 6.2831853d0    !            Two times pi

  integer,parameter::n_U=1+nIons+2*nGroups     ! # of vars in state vector
  integer,parameter::iT=1                            !       Indexes in U
  integer,parameter::ix0=2, ix1=1+nIons              !            --
  integer,parameter::iNp0=2+nIons                    !            --
  integer,parameter::iNp1=1+nIons+nGroups            !            --
  integer,parameter::iFp0=2+nIons+nGroups            !            --
  integer,parameter::iFp1=1+nIons+2*nGroups          !            --
  integer,dimension(nGroups)::iNpU,iFpU              !       See set_model
  real(dp),dimension(n_U)::U_MIN, U_frac, U_FM       !       See set_model
  integer::iUxHI=0,iUxHII=0,iUxHeII=0,iUxHeIII=0     !   xion indexes in U

  ! Cooling constants, updated on SED and c change [cm3 s-1],[erg cm3 s-1]
  real(dp),dimension(nGroups,nIons)::signc,sigec,PHrate

  real(dp),dimension(nIons, 2)::UVrates     !UV backgr. heating/ion. rates

CONTAINS 

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_set_model(Nmodel, J0in_in, J0min_in, alpha_in, normfacJ0_in, &
     zreioniz_in, correct_cooling, realistic_ne, h, omegab, omega0,      &
     omegaL, astart_sim, T2_sim)
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
  real(kind=8) :: J0in_in, zreioniz_in, J0min_in, alpha_in, normfacJ0_in
  real(kind=8) :: astart_sim, T2_sim, h, omegab, omega0, omegaL
  integer  :: Nmodel, correct_cooling, realistic_ne, ig
  real(kind=8) :: astart=0.0001, aend, dasura, T2end, mu, ne
!-------------------------------------------------------------------------
  ! Do initialization
  U_MIN(iT)       = 0.1                  !                        T2 floor
  U_FRAC(iT)      = 0.1                  !    Max fractional change per dt
  U_FM(iT)        = 0.1                  !  Min at which to consider frac.

  U_MIN(ix0:ix1)  = 1d-20                !     Ionization fraction floor
  U_FRAC(ix0:ix1) = 0.1    
  U_FM(ix0:ix1)  = 1d-6 

  U_MIN(iNp0:iNp1) = 1d-25               !            Photon density floor
  U_FRAC(iNp0:iNp1) = 0.2    
  U_FM(iNp0:iNp1) = 1d-13 

  U_MIN(iFp0:iFp1)  = 0d0                !           Minimum photon fluxes
  U_FRAC(iFp0:iFp1) = 0.2
  U_FM(iFp0:iFp1)  = 1d-13*rt_c_cgs
  ! Set up indexes of ionization states in U:
  if(isH2) iUxHI = ix0-1+ixHI
  iUxHII = ix0-1+ixHII
  if(isHe) iUxHeII = ix0-1+ixHeII
  if(isHe) iUxHeIII = ix0-1+ixHeIII
  if(myid==1) print*,'ix=',ixHI,ixHII,ixHeII,ixHeIII
  if(myid==1) print*,'iUx=',iUxHI,iUxHII,iUxHeII,iUxHeIII 

  ! Set up indexes of photon densities and fluxes in U:
  do ig=0,nGroups-1
     iNpU(ig+1)=iNp0+ig
     iFpU(ig+1)=iFp0+ig
  enddo

  ! Might also put in here filling in of tables of cooling rates, to 
  ! ease the computational load.

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

  if(nrestart==0 .and. cosmo)                                            &
       call rt_evol_single_cell(astart,aend,dasura,h,omegab,omega0       &
                               ,omegaL,-1.0d0,T2end,mu,ne,.false.)
  T2_sim=T2end

END SUBROUTINE rt_set_model

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE update_UVrates
! Set the UV ionization and heating rates according to the given a_exp.
!------------------------------------------------------------------------
  use UV_module
  use amr_parameters,only:aexp
  integer::i
!------------------------------------------------------------------------
  UVrates=0.
  if(.not. rt_UV_hom) RETURN
  
  call inp_UV_rates_table(1./aexp - 1., UVrates)

  !if(myid==1) then
  !   write(*,*) 'The UV rates have changed to:'
  !   do i=1,nIons
  !      write(*,910) UVrates(i,:)
  !   enddo
  !zendif
910 format (1pe21.6, ' s-1', 1pe21.6,' erg s-1')
END SUBROUTINE update_UVrates

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_solve_cooling(U, dNpdt, dFpdt, nH, c_switch, Zsolar        &
                          , dt, a_exp, nCell)
! Semi-implicitly solve for new temperature, ionization states, 
! photon density and flux in a number of cells.
! parameters: 
! U      <=>  Cell state:    (T/mu [K], x_j, Np_i [cm-3], Fp_i [cm-2 s-1])
! dNpdt   =>  Op split increment in photon densities during dt
! dFpdt   =>  Op split increment in photon flux magnitudes during dt
! c_switch=>  Cooling switch (1 for cool/heat, 0 for no cool/heat)
! Zsolar  =>  Cell metallicities [solar fraction]
! nH      =>  Hydrogen number densities [cm-3]  
! dt      =>  Timestep size             [s]
! a_exp   =>  Cosmic expansion
! nCell   =>  Number of cells (length of all the above vectors)
!
! We use a slightly modified method of Anninos et al. (1997).
!-------------------------------------------------------------------------
  use amr_commons
  implicit none  
  real(dp),dimension(1:nvector, n_U):: U
  real(dp),dimension(1:nvector, nGroups)::dNpdt,dFpdt
  real(dp),dimension(1:nvector):: nH, Zsolar
  logical,dimension(1:nvector)::c_switch
  real(dp)::dt, a_exp
  integer::ncell !--------------------------------------------------------
  real(dp),dimension(1:nvector):: tLeft, ddt, nHe=0d0
  logical:: dt_ok
  real(dp)::dt_rec
  real(dp),dimension(n_U):: dU
  integer::i, ia,  nAct, nAct_next, loopcnt, code
  integer,dimension(1:nvector):: indAct              ! Active cell indexes
!-------------------------------------------------------------------------
  tleft(1:ncell) = dt                !       Time left in dt for each cell
  ddt(1:ncell) = dt                  ! First guess at sub-timestep lengths
  if(isHe) nHe(1:ncell)=0.25*nH(1:ncell)*Y/X ! Helium density in each cell

  do i=1,ncell
     indact(i) = i                   !      Set up indexes of active cells
     ! Ensure all state vars are legal:
     U(i,1) = MAX(U(i,1), T2_min_fix)                        ! Temperature
     U(i,iUxHII) = MIN(MAX(U(i,iUxHII), U_MIN(iUxHII)),1.d0)        ! xHII
     if(isH2) then
        U(i,iUxHI) = MIN(MAX(U(i,iUxHI), U_MIN(iUxHI)),1.d0)        !  xHI
        ! Ensure the total hydrogen fraction is 1:
        if(U(i,iUxHI)+U(i,iUxHII) .gt. 1.d0) then
           if(U(i,iUxHI) .gt. U(i,iUxHII)) then
              U(i,iUxHI)=1.d0-U(i,iUxHII)
           else
              U(i,iUxHII)=1.d0-U(i,iUxHI)
           endif
        endif ! total hydrogen fraction
     endif ! isH2

     if(isHe) then                                        ! Helium species
        U(i,iUxHeII)  = MIN(MAX(U(i,iUxHeII),  U_MIN(iUxHeII)), 1.d0)
        U(i,iUxHeIII) = MIN(MAX(U(i,iUxHeIII), U_MIN(iUxHeIII)),1.d0)
        ! Ensure the total hydrogen fraction is 1:
        if(U(i,iUxHeII)+U(i,iUxHeIII) .gt. 1.d0) then
           if(U(i,iUxHeII) .gt. U(i,iUxHeIII)) then
              U(i,iUxHeII)=1.d0-U(i,iUxHeIII)
           else
              U(i,iUxHeIII)=1.d0-U(i,iUxHeII)
           endif 
        endif ! total helium fraction
     endif ! isHe

     ! Photons groups
     U(i,iNp0:iNp1)= MAX(smallNp, U(i,iNp0:iNp1))
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
        if(loopcnt .gt. 100000) &
             call display_CoolInfo(.true., loopcnt, i, dt-tleft(i), dt,  & 
                                ddt(i),nH(i), U(i,:), dU, code)
        call cool_step(U(i,:), dNpdt(i,:), dFpdt(i,:), ddt(i), nH(i)     &
                     ,nHe(i), Zsolar(i), a_exp, dt_ok, dt_rec            &
                     ,c_switch(i), dU, i, loopcnt, code)
        if(.not. dt_ok) then  
           ddt(i)=ddt(i)/2.                    ! Try again with smaller dt 
           nAct_next=nAct_next+1 ; indAct(nAct_next) = i
           loopCodes(code) = loopCodes(code)+1
           cycle 
        endif
        U(i,:) = U(i,:) + dU         !  Update U (advance the time by ddt)
        tleft(i)=tleft(i)-ddt(i)
        if(tleft(i) .gt. 0.) then           ! Not finished with this cell
           nAct_next=nAct_next+1 ; indAct(nAct_next) = i
        else if(tleft(i) .lt. 0.) then        ! Overshot by abs(tleft(i))
           U(i,:)  = U(i,:)  + tleft(i)/ddt(i) * dU
           ddt(i)  = ddt(i)  + tleft(i)
        endif
        ddt(i)=dt_rec              ! Use the recommended dt from cool_step
     end do ! end loop over active cells
     nAct=nAct_next
  end do ! end iterative loop
  ! loop statistics
  max_cool_loopcnt=max(max_cool_loopcnt,loopcnt)
END SUBROUTINE rt_solve_cooling


!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE cool_step(U, dNpdt, dFpdt, dt, nH, nHe, Zsolar, a_exp         &  
                     ,dt_ok  ,dt_rec, c_switch, dU, nc, loopcnt, code)
! Compute change dU in state-vector U for a cell in timestep dt, or 
! return a recommendation for new timestep-length if dt proves too large.
! U       =>  cell state (cgs)
! dNpdt   =>  per sec increment in photon densities
! dFpdt   =>  per sec increment in photon flux magnitudes
! dt      =>  timestep length (s)
! nH      =>  cell hydrogen number density (cgs)
! nHe     =>  cell helium number density (cgs)
! Zsolar  =>  Cell metallicity (fraction of solar)
! a_exp   =>  Cosmic expansion factor
! dt_ok   <=  .f. if timestep constraints were broken, .t. otherwise
! dt_rec  <=  Recommended timesteps for next iteration
! c_switch=>  Cooling switch (1=on, 0=off)
! dU      <=  Change in U during timestep
! nc       =>  Id of cell (for debug purposes)
! loopcnt  =>  Number of iteration for cell (for debug)
! code    <= Error code in cool step, if dt_ok=.f.
!-------------------------------------------------------------------------
  use UV_module, ONLY: iUVvars_cool, UV_Nphot_cgs
  use amr_commons
  use const
  implicit none  
  real(dp),dimension(n_U):: U, dU
  real(dp),dimension(nGroups):: dNpdt, dFpdt
  real(dp):: nH, nHe, Zsolar, dt_rec, dt, a_exp
  logical::dt_ok, c_switch!-----------------------------------------------
  real(dp),dimension(nIons),save:: alpha, beta, nN, nI
  real(dp):: mu, TK, ne, neInit, Hrate, q, betaH2, ndust
  real(dp):: xHI=0d0, xHeI=0d0, xHeII=0d0, xHeIII=0d0
  real(dp):: Crate, dCdT2, X_nHkb, rate, dRate, dUU, cr, de, photoRate
  real(dp),dimension(nGroups):: recRad, phI, signcdust
  real(dp)::metal_tot,metal_prime
  real(dp)::xH2!sln, tmp, change later maybe
  integer::i, nc, loopcnt, code
  real(dp):: fracMax
!-------------------------------------------------------------------------
  dt_ok=.false.
  ! Insert UV background emitted and propagated from void regions:
  if(rt_isDiffuseUVsrc .and. nH .le. rt_UVsrc_nHmax) &
       & U(iUVvars_cool) = max(U(iUVvars_cool), UV_Nphot_cgs)
  dU=U ! U contains the original values, dU the updated ones
  ! nN(1) == nN(ixHI)    == nH2           ! nI(1) == nI(ixHI)    == nHI
  ! nN(2) == nN(ixHII)   == nHI           ! nI(2) == nI(ixHII)   == nHII
  ! nN(3) == nN(ixHeII)  == nHeI          ! nI(3) == nI(ixHeII)  == nHeII
  ! nN(4) == nN(ixHeIII) == nHeII         ! nI(4) == nI(ixHeIII) == nHeIII
  xHI = 1d0-dU(iUxHII)                    !     Need in case of .not. isH2
  xH2 = 0d0                               !                       This too
  if(isH2) xHI = dU(iUxHI)
  ! xHII   = dU(iUxHII) (always exists)
  if(isHe) xHeII = dU(iUxHeII)
  if(isHe) xHeIII = dU(iUxHeIII)
  if(isHe) xHeI=MAX(1.-xHeII-xHeIII,0.d0)
  if(isH2) xH2 =MAX(1.-xHI-dU(iUxHII),0.d0)/2.
  ! nN='neutral' species (pre-ionized)
  if(isH2) nN(ixHI) = nH * xH2                       		 !     nH2
  nN(ixHII) = nH * xHI                                           !     nHI
  if(isHe) nN(ixHeII)  = nHe*xHeI                                !    nHeI
  if(isHe) nN(ixHeIII) = nHe*dU(iUxHeII)		         !   nHeII
  ! nI=ionized counterparts of the neutral species
  if(isH2) nI(ixHI)  = nN(ixHII)                                 !     nHI
  nI(ixHII) = nH * dU(iUxHII)                                    !    nHII
  if(isHe) nI(ixHeII)  = nN(ixHeIII)                             !   nHeII
  if(isHe) nI(ixHeIII) = nHe*dU(iUxHeIII)                        !  nHeIII
  mu = 1./(X*(0.5+0.5*xHI+1.5*dU(iUxHII)) + 0.25*Y*(1.+xHeII+2.*xHeIII))
  TK = U(1) * mu                                            !  Temperature
  if(rt_isTconst) TK=rt_Tconst                         !  Force constant T
  ne= nH*dU(iUxHII)+nHe*(xHeII+2.*xHeIII)              !  Electron density
  neInit=ne
  fracMax=0d0    ! Max. fractional update, to check if dt can be increased

  ! UPDATE PHOTON DENSITY AND FLUX ***************************************
  if(rt) then 
     ! Must have this line if restriction on the Fp fractional change:
     U(iFp0:iFp1) = MAX(0D0,MIN(U(iFp0:iFp1), U(iNp0:iNp1)*rt_c_cgs))
     recRad(1:nGroups)=0. ; phI(1:nGroups)=0.              
     if(.not. rt_OTSA .and. rt_advect) then ! ------------- Rec. radiation
        if(isH2) alpha(ixHI) = 0.d0 ! H2 emits no recombination radiation?
        alpha(ixHII) = comp_AlphaA_HII(TK) - comp_AlphaB_HII(TK) 
        if(isHe) then                                                         
           ! alpha(HeII) (A-B) becomes negative around 1K, hence the max:
           alpha(ixHeII) = &
                       MAX(0.d0,comp_AlphaA_HeII(TK)-comp_AlphaB_HeII(TK))
           alpha(ixHeIII) = comp_AlphaA_HeIII(TK) - comp_AlphaB_HeIII(TK)
        endif
        do i=1,nIons
           if(spec2group(i) .gt. 0)   & ! Contribution of ion -> ph. group
                recRad(spec2group(i)) = &
                recRad(spec2group(i)) + alpha(i) * nI(i) * ne
        enddo
     endif !if non-OTSA
     signcdust(:)=2.0d-21*rt_c_cgs ! Dust absorption cross-sections cm^2 times c
     ndust=Zsolar*nH*(xHI+2.0*xH2) ! No dust in ionized hydrogen
     do i=1,nGroups      ! ------------------------------------ Absorbtion
        phI(i) = SUM(nN(:)*signc(i,:)) + ndust*signcdust(i)
     end do

     do i=1,nGroups      ! ---------------------- Do the update of N and F
        dU(iNpU(i))= MAX(smallNp,                                        &
                   (dt*(recRad(i)+dNpdt(i))+dU(iNpU(i)))/(1.d0+dt*phI(i)))
        dU(iFpU(i)) = MAX(0d0,(dt*dFpdt(i)+dU(iFpu(i)))/(1.d0+dt*phI(i)))
        ! Check the flux: Too large relative to available photons? 
        q = dU(iFpU(i)) / (rt_c_cgs*dU(iNpU(i)))
        if(q .gt. 1.d0) then           ! Normalize flux if it is too large
           dU(iFpU(i))=dU(iFpU(i))/q
        endif
     end do
     dUU=MAXVAL( & ! Fractional changes in photon densities
        ABS((dU(iNp0:iNp1)-U(iNp0:iNp1))/(U(iNp0:iNp1)+U_FM(iNp0:iNp1))) &
        /U_FRAC(iNp0:iNp1) )                                             
     if(dUU .gt. 1.) then                                 
       code=1 ;   dU=dU-U; RETURN                             ! dt too big
     endif
     fracMax=MAX(fracMax,dUU)
     dUU=MAXVAL( & ! Fractional changes in photon fluxes
        ABS((dU(iFp0:iFp1)-U(iFp0:iFp1))/(U(iFp0:iFp1)+U_FM(iFp0:iFp1))) &
        /U_FRAC(iFp0:iFp1) )                                              
     if(dUU .gt. 1.) then                                                 
       code=1 ;   dU=dU-U; RETURN                             ! dt too big
     endif                                                                
     fracMax=MAX(fracMax,dUU)                                             
  endif !if(rt)

  ! UPDATE TEMPERATURE ***************************************************
  if(c_switch .and. cooling) then
     Hrate=0.                               !  Heating rate [erg cm-3 s-1]
     if(rt) then
        do i=1,nGroups                                     !  Photoheating
           Hrate = Hrate + dU(iNpU(i)) * SUM(nN(:) * PHrate(i,:))
        end do
     endif
     if(rt_UV_hom .and. nH .lt. rt_UV_nHSS)                              &
          Hrate = Hrate + SUM(nN(:) * UVrates(:,2))
     Crate=compCoolrate(TK, ne, nH, nN, nI, a_exp, dCdT2, RT_OTSA)!Cooling
     dCdT2 = dCdT2 * mu                             !  dC/dT2 = mu * dC/dT
     metal_tot=0.d0 ; metal_prime=0.d0                     ! Metal cooling
     call rt_cmp_metals(U(1),nH,mu,metal_tot,metal_prime,a_exp)

     X_nHkb= X/(1.5 * nH * kB)                     ! Multiplication factor   
     rate  = X_nHkb*(Hrate - Crate - Zsolar*metal_tot)
     dRate = -X_nHkb*(dCdT2 + Zsolar*metal_prime)              ! dRate/dT2
     if(rt_isTconst)then
        rate=0.
        dRate=0.
     endif
     dUU   = ABS(MAX(T2_min_fix, U(1)+rate*dt)-U(1)) ! 1st order dt constr
     dU(1) = MAX(T2_min_fix, U(1)+rate*dt/(1.-dRate*dt))    ! New T2 value
     dUU   = MAX(dUU, ABS(dU(1)-U(1))) / (U(1)+U_FM(1)) / U_FRAC(1)
     if(dUU .gt. 1.) then                                       ! 10% rule
        code=2 ; dU=dU-U; RETURN
     endif
     fracMax=MAX(fracMax,dUU)
     TK=dU(1)*mu
     if(rt_isTconst)TK=rt_TConst
  endif ! if(c_switch and cooling)

  ! HYDROGEN UPDATE*******************************************************

  if(isH2) then ! UPDATE xH2**********************************************
     alpha(ixHI) = comp_Alpha_H2(TK,Zsolar)           ! H2 formation rates
     beta(ixHI) = comp_Beta_H2HI(TK)   ! H2 collisional dissociation rates
     cr = alpha(ixHI) * nH * dU(iUxHI)                    !    H2 Creation
     photoRate=0.
     if(rt) photoRate = SUM(signc(:,ixHI)*dU(iNp0:iNp1))
     if(rt_UV_hom .and. nH .lt. rt_UV_nHSS)                              &
          photoRate = photorate + UVrates(ixHI,1)
     de = beta(ixHI) * nH + photoRate                     ! H2 Destruction
     xH2 = (cr*dt+xH2)/(1.+de*dt)
     xH2 = MIN(MAX(xH2, 0.),0.5)     
  endif !if(isH2)

  ! UPDATE xHI (also if .not. isH2, for stability)************************
  if(rt_OTSA .or. .not. rt_advect) then           !    Recombination rates
     alpha(ixHII) = comp_AlphaB_HII(TK)
  else                               
     alpha(ixHII) = comp_AlphaA_HII(TK)
  endif
  beta(ixHII) = comp_Beta_HI(TK)                !    Coll. ionization rate
  cr = alpha(ixHII) * ne * dU(iUxHII) + 2. * de * xH2     !    HI creation
  photoRate=0.
  if(rt) photoRate = SUM(signc(:,ixHII)*dU(iNp0:iNp1))    !          [s-1]
  if(rt_UV_hom .and. nH .lt. rt_UV_nHSS)                                 &
       photoRate = photorate + UVrates(ixHII,1)
  de = beta(ixHII) * ne + photoRate                       ! HI destruction
  if(isH2) de = de + 2. * alpha(ixHI) * nH                ! HI destruction
  xHI = (cr*dt+xHI)/(1.+de*dt)
  xHI = MIN(MAX(xHI, U_MIN(iUxHII)),1.) !Must be U_min(iUxHII) (if not H2)
  if(isH2) then                   ! Update U and check timestep constraint
     dU(iUxHI)=xHI
     dUU= ABS((dU(iUxHI)-U(iUxHI))) /(U(iUxHI)+U_FM(iUxHI)) /U_FRAC(iUxHI)
     if(dUU .gt. 1.) then
        code=5 ; dU=dU-U; RETURN
     endif
     fracMax=MAX(fracMax,dUU)
  endif

  ! UPDATE xHII***********************************************************
  if(rt) photoRate = SUM(signc(:,ixHII)*dU(iNp0:iNp1))    !          [s-1]
  if(rt_UV_hom .and. nH .lt. rt_UV_nHSS)                                 &
       photoRate = photorate + UVrates(ixHII,1)
  cr = (beta(ixHII)*ne+photoRate)*xHI             !               Creation
  de = alpha(ixHII) * ne                          !            Destruction
  dU(iUxHII) = (cr*dt+dU(iUxHII))/(1.+de*dt)
  dU(iUxHII) = MIN(MAX(dU(iUxHII), U_MIN(iUxHII)),1.d0)

  ! Atomic conservation of H *********************************************
  if(isH2) then
     if(2.*xH2.ge.dU(iUxHII)) then    !   Either H2 or HI is most abundant
        if(2.*xH2.le.dU(iUxHI)) dU(iUxHI)=1.-2.*xH2-dU(iUxHII)     ! -> HI
     else                             !  Either HI or HII is most abundant 
        if(dU(iUxHI).le.dU(iUxHII)) then 
           dU(iUxHII) = 1.-2.*xH2-dU(iUxHI)                         !  HII
        else
           dU(iUxHI) = 1.-2.*xH2-dU(iUxHII)                         !   HI
        endif
     endif
  else
     if(xHI.le.dU(iUxHII)) dU(iUxHII) = 1.-xHI                      !  HII
  endif ! if(isH2)

  ! Timestep ok for HII update?
  dUU= ABS(dU(iUxHII)-U(iUxHII)) /(U(iUxHII)+U_FM(iUxHII)) /U_FRAC(iUxHII)
  if(dUU .gt. 1.) then
     code=3 ; dU=dU-U; RETURN
  endif
  fracMax=MAX(fracMax,dUU)

  ! HELIUM UPDATE*********************************************************

  if(isHe) then 
     ! Update ne because of changed xhii:
     ne= nH*dU(iUxHII)+nHe*(dU(iUxHeII)+2.*dU(iUxHeIII))
     xHI = 1d0-dU(iUxHII)
     if(isH2) xHI = dU(iUxHI)
     mu= 1./(X*(0.5+0.5*xHI+1.5*dU(iUxHII)) + 0.25*Y*(1.+xHeII+2.*xHeIII))
     if(.not. rt_isTconst) TK=dU(1)*mu !  Update TK because of changed  mu

     ! UPDATE xHeI *******************************************************
     if(rt_OTSA .or. .not. rt_advect) then
        alpha(ixHeII)  = comp_AlphaB_HeII(TK)
        alpha(ixHeIII) = comp_AlphaB_HeIII(TK)
     else                               
        alpha(ixHeII)  = comp_AlphaA_HeII(TK)
        alpha(ixHeIII) = comp_AlphaA_HeIII(TK)
     endif
     beta(ixHeII)  = comp_Beta_HeI(TK)
     beta(ixHeIII) = comp_Beta_HeII(TK)
     ! Creation = recombination of HeII and electrons
     cr = alpha(ixHeII) * ne * dU(iUxHeII)
     ! Destruction = collisional ionization + photoionization of HeI
     de = beta(ixHeII) * ne
     if(rt) de = de + SUM(signc(:,ixHeII)*dU(iNp0:iNp1))
     if(rt_UV_hom .and. nH .lt. rt_UV_nHSS) de = de + UVrates(ixHeII,1)
     xHeI = (cr*dt+xHeI)/(1.+de*dt)                          !  The update
     xHeI = MIN(MAX(xHeI, 0.),1.)

     ! UPDATE xHeII ******************************************************
     ! Creation = coll.- and photo-ionization of HeI + rec. of HeIII
     cr = de * xHeI + alpha(ixHeIII) * ne * dU(iUxHeIII)
     ! Destruction = rec. of HeII + coll.- and photo-ionization of HeII
     photoRate=0.
     if(rt) photoRate = SUM(signc(:,ixHeIII)*dU(iNp0:iNp1))
     if(rt_UV_hom .and. nH.lt.rt_UV_nHSS) &
                                photoRate = photoRate + UVrates(ixHeIII,1)
     de = (alpha(ixHeII) + beta(ixHeIII)) * ne + photoRate
     dU(iUxHeII) = (cr*dt+dU(iUxHeII))/(1.+de*dt)            !  The update
     dU(iUxHeII) = MIN(MAX(dU(iUxHeII), U_MIN(iUxHeII)),1.)

     ! UPDATE xHeIII *****************************************************
     ! Creation = coll.- and photo-ionization of HeII
     cr = (beta(ixHeIII) * ne + photoRate) * dU(iUxHeII)   !  xHeII is new
     ! Destruction = rec. of HeIII and e
     de = alpha(ixHeIII) * ne
     dU(iUxHeIII) = (cr*dt+dU(iUxHeIII))/(1.+de*dt)            !  The update
     dU(iUxHeIII) = MIN(MAX(dU(iUxHeIII), U_MIN(iUxHeIII)),1.)

     ! ATOMIC CONSERVATION OF He *****************************************
     if(xHeI .ge. dU(iUxHeIII)) then ! Either HeI or HeII is most abundant 
        if(xHeI .le. dU(iUxHeII)) dU(iUxHeII) = 1.-xHeI-dU(iUxHeIII) !HeII
     else                          ! Either HeII or HeIII is most abundant 
        if(dU(iUxHeII) .le. dU(iUxHeIII)) then
           dU(iUxHeIII) = 1. - xHeI-dU(iUxHeII)                   !  HeIII
        else
           dU(iUxHeII) = 1. - xHeI-dU(iUxHeIII)                    !  HeII
        endif
     endif
  endif !if(isHe) ! END HELIUM UPDATE*************************************

  ne = nH*dU(iUxHII)
  if(isHe) ne = ne + nHe*(dU(iUxHeII)+2.*dU(iUxHeIII))
  dUU=ABS((ne-neInit)) / (neInit+U_FM(iUxHII)) / U_FRAC(iUxHII)
  if(dUU .gt. 1.) then
     code=4 ; dU=dU-U; RETURN
  endif
  fracMax=MAX(fracMax,dUU)

  ! compute new mu
  if(rt_isTconst)then 
     xHI = 1d0-dU(iUxHII)
     if(isH2) xHI = dU(iUxHI)
     xHeII=0.
     xHeIII=0.
     if(isHe) xHeII = dU(iUxHeII)
     if(isHe) xHeIII = dU(iUxHeIII)
     mu= 1./(X*(0.5+0.5*xHI+1.5*dU(iUxHII)) + 0.25*Y*(1.+xHeII+2.*xHeIII))
     dU(1)=rt_Tconst/mu
  endif

  ! Check if we are safe to use a bigger timestep in next iteration:
  dU=dU-U
  if(fracMax .lt. 0.5) then
     dt_rec=dt*2.
  else
     dt_rec=dt
  endif
  dt_ok=.true.
  code=0

END SUBROUTINE cool_step

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE display_U_change(U_old, U_new, nH, loopcnt, code)

! Print cooling information to standard output.
!-------------------------------------------------------------------------
  use amr_commons
  use rt_parameters
  real(dp),dimension(n_U):: U_old, U_new
  real(dp)::nH, nHe, ne_old, ne_new
  integer::i, loopcnt, code
!-------------------------------------------------------------------------
  nHe=0.5*nH*Y/X
  ne_old= nH*U_old(iUxHII)+nHE*(U_old(iUxHeII)+2.*U_old(iUxHeIII))
  ne_new= nH*U_new(iUxHII)+nHE*(U_new(iUxHeII)+2.*U_new(iUxHeIII))
  print *,'U: var------------old-----------new------------dU--'
  write(*,777)'T',    U_old(1), U_new(1), abs((U_new(1)-U_old(1))/U_old(1))
  if(isH2)  write(*,888)'xHI',U_old(iUxHI), U_new(iUxHI)                 &
                           , abs((U_new(iUxHI)-U_old(iUxHI))/U_old(iUxHI))
  write(*,888)'xHII',   U_old(iUxHII), U_new(iUxHII)                     &
                         ,abs((U_new(iUxHII)-U_old(iUxHII))/U_old(iUxHII))
  if(isHe) write(*,888)'xHeII',  U_old(iUxHeII), U_new(iUxHeII)          &
                     , abs((U_new(iUxHeII)-U_old(iUxHeII))/U_old(iUxHeII))
  if(isHe) write(*,888)'xHeIII', U_old(iUxHeIII), U_new(iUxHeIII)        &
                  , abs((U_new(iUxHeIII)-U_old(iUxHeIII))/U_old(iUxHeIII))
  write(*,777)'ne',     ne_old,   ne_new,   abs((ne_new-ne_old)/ne_old)
  write(*,999), loopcnt, code, nH, nHe
  do i=0,nGroups-1
     write(*,777)'Np',  U_old(iNp0+i), U_new(iNp0+i), &
          abs((U_new(iNp0+i)-U_old(iNp0+i))/U_old(iNp0+i))
  enddo
  print *,'  -------------------------------------------------'

777 format('  ', A6, '   ', 1pe11.3, '   ', 1pe11.3, '   ',  1pe11.3)
888 format('  ', A6, '   ', F11.6,   '   ', F11.6,   '   ',  F11.6)
999 format('     lcnt=',I6, '        code=', I2, '        nH=', 1pe11.3,&
           '        nHe=', 1pe11.3)
END SUBROUTINE display_U_change

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE display_coolinfo(stopRun, loopcnt, i, dtDone, dt, ddt, nH,   &
                            U, dU, code)

! Print cooling information to standard output, and maybe stop execution.
!------------------------------------------------------------------------
  use amr_commons
  use rt_parameters
  logical::stopRun
  integer::loopcnt,i, code
  real(dp)::dtDone, dt, ddt, nH
  real(dp),dimension(n_U):: U, dU
!------------------------------------------------------------------------
  if(stopRun) write(*, 111) loopcnt
  if(.true.) then
     write(*,900) loopcnt, myid, code, i, dtDone, dt, ddt, rt_c_cgs, nH
     write(*,901) U
     write(*,902) dU
     write(*,903) dU/ddt
     write(*,904) abs(dU)/(U+U_FM)
  endif
  if(stopRun) then
     print *,'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
     STOP
  endif

111 format(' Stopping because of large number of timestesps in', &
           ' rt_solve_cooling (', I6, ')')
900 format (I3, '  myid=', I2, ' code=', I2, ' i=', I5, ' t=', 1pe12.3,  xs&
            '/', 1pe12.3, ' ddt=', 1pe12.3, ' c=', 1pe12.3, &
            ' nH=', 1pe12.3)
901 format ('  U      =', 20(1pe12.3))
902 format ('  dU     =', 20(1pe12.3))
903 format ('  dU/dt  =', 20(1pe12.3))
904 format ('  dU/U % =', 20(1pe12.3))
END SUBROUTINE display_coolinfo


!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE cmp_chem_eq(TK, nH, t_rad_spec, nSpec, nTot, mu, Zsol)

! Compute chemical equilibrium abundances of e, H2, HI, HII, HeI, HeII, HeIII
! r_rad_spec => photoionization rates [s-1] for H2, HI, HeI, HeII
!------------------------------------------------------------------------
  implicit none
  real(dp),intent(in)::TK, nH, Zsol
  real(dp),intent(out)::nTot, mu
  real(dp),dimension(nIons),intent(in)::t_rad_spec
  real(dp),dimension(1:7),intent(out)::nSpec!------------------------
  real(dp)::nHe
  real(dp)::n_H2, n_HI, n_HII, n_HEI, n_HEII, n_HEIII, n_E, n_E_min
  real(dp)::g_H2,  g_HI,    g_HEI,  g_HEII  ! Photoionisation/dissociation
  real(dp)::a_H2,  a_HI,    a_HEI,  a_HEII  ! Recombination
  real(dp)::b_H2,  b_HI,    b_HEI,  b_HEII  ! Collisional ionisation
  real(dp)::C_HII, D_H2,    f_HII,  f_H2    ! Creation and destruction
  real(dp)::D_HEI, C_HEIII, f_HeI,  f_HeIII ! Creation and destruction
  real(dp)::err_nE, err_nH2, n_H2_old
!-------------------------------------------------------------------------
  if(isHe) nHe = Y/(1.-Y)/4.*nH
  if(isH2) g_H2 = t_rad_spec(ixHI)             !   Photodissociation [s-1]
  g_HI   = t_rad_spec(ixHII)                   !     Photoionization [s-1]
  if(isHe) g_HEI  = t_rad_spec(ixHeII)
  if(isHe) g_HEII = t_rad_spec(ixHeIII)
  if(isH2) a_H2 = comp_Alpha_H2(TK, Zsol)     ! HI recombination [cm3 s-1]
  if(rt_OTSA) then                             !   Recombination [cm3 s-1]
     a_HI   = comp_AlphaB_HII(TK)
     a_HEI  = comp_AlphaB_HeII(TK)
     a_HEII = comp_AlphaB_HeIII(TK)
  else
     a_HI   = comp_AlphaA_HII(TK)
     a_HEI  = comp_AlphaA_HeII(TK)
     a_HEII = comp_AlphaA_HeIII(TK)
  endif
  b_H2 = comp_Beta_H2HI(TK)                 ! Coll. dissociation [cm3 s-1]
  b_HI = comp_Beta_HI(TK)                     ! Coll. ionization [cm3 s-1]
  if(isHe) b_HEI  = comp_Beta_HeI(TK)
  if(isHe) b_HEII = comp_Beta_HeII(TK)

  n_E = nH     ; n_H2 = 0d0    ; n_H2_old = nH/2d0
  n_HeI=0d0    ; n_HeII=0d0    ; n_HeIII=0d0
  err_nE = 1d0 ; err_nH2=0d0     ! err_nH2 initialisation in case of no H2
  do while(err_nE > 1d-8 .or. err_nH2 > 1d-8)

     n_E_min = MAX(n_E,1e-15*nH)
     C_HII = b_HI * n_E_min + g_HI                  !   HII creation (s-1)
     f_HII = C_HII / a_HI / n_E_min                 ! Cre/Destr [unitless]
     f_H2 = 0d0
     if(isH2) then
        D_H2  = b_H2 * nH  + g_H2                   !      H2 destr. (s-1)
        f_H2  = a_H2*nH / D_H2                      ! Cre/Destr [unitless]
        n_H2  = nH / (2d0 + 1d0/f_H2 + f_HII/f_H2)
     endif ! if(isH2)
     n_HI  = nH / (1d0 + f_HII + 2d0*f_H2)
     n_HII = nH / (1d0 + 1d0/f_HII + 2d0*f_H2/f_HII)

     if(isHe) then
        D_HeI   = b_HEI*n_E_min  + g_HEI           !  HeI destr. (s-1)
        C_HeIII = b_HEII*n_E_min + g_HEII          !  HeIII cre. (s-1)
        f_HeI   = D_HeI / a_HeI / n_E_min          !  Destr/Cre [unitless]
        f_HeIII = a_HeII * n_E_min / C_HeIII       !  Destr/Cre [unitless]

        n_HEI   = nHe / (1d0 + f_HeI + f_HeI/f_HeIII)
        n_HEII  = nHe / (1d0 + 1d0/f_HeI + 1d0/f_HeIII)
        n_HEIII = nHe / (1d0 + f_HeIII + f_HeIII/f_HeI)
     endif ! if(isHe)

     err_nE = ABS((n_E - (n_HII + n_HEII + 2.*n_HEIII))/nH)
     n_E = 0.5*n_E+0.5*(n_HII + n_HEII + 2.*n_HEIII)

     if(isH2) then
        err_nH2 = ABS((n_H2_old - n_H2)/nH)
        n_H2_old = n_H2
     endif

  end do

  nTOT     = n_E+n_H2+n_HI+n_HII+n_HEI+n_HEII+n_HEIII
  mu       = nH/(1.-Y)/nTOT
  nSpec(1) = n_E
  nSpec(2) = n_H2
  nSpec(3) = n_HI
  nSpec(4) = n_HII
  nSpec(5) = n_HEI
  nSpec(6) = n_HEII
  nSpec(7) = n_HEIII

END SUBROUTINE cmp_chem_eq

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
SUBROUTINE rt_evol_single_cell(astart,aend,dasura,h,omegab,omega0,omegaL   &
                           ,J0min_in,T2end,mu,ne,if_write_result)
!------------------------------------------------------------------------
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
  real(dp)::aexp,daexp,dt_cool,coeff
  real(dp)::T2_com,T2_old,T2,T2_left,T2_right,err_T2
  real(dp)::nH_com  
  real(dp),dimension(nIons)::pHI_rates=0., h_rad_spec=0.
  real(kind=8) ::mu
  real(dp) ::cool_tot,heat_tot, mu_dp
  real(dp) ::diff
  integer::niter
  real(dp) :: n_spec(1:7)
  real(dp),dimension(1:nvector, n_U)::U=0.
  real(dp),dimension(1:nvector,nGroups)::dNpdt=0., dFpdt=0.
  real(dp),dimension(1:nvector)::nH=0., Zsolar=0.
  logical,dimension(1:nvector)::c_switch=.true.
!-------------------------------------------------------------------------
  aexp = astart
  T2_com = 2.726d0 / aexp * aexp**2 / mu_mol
  nH_com = omegab*rhoc*h**2*X/mH

  mu_dp=mu
  call cmp_Equilibrium_Abundances(                                       &
                 T2_com/aexp**2, nH_com/aexp**3, pHI_rates, mu_dp, n_Spec, Zsolar)
  ! Initialize cell state
  U(1,1)=T2_com                                         !   Temperature
  if(isH2) U(1,iUxHI)=n_Spec(3)/(nH_com/aexp**3)        !   HI frac
  U(1,iUxHII)=n_Spec(4)/(nH_com/aexp**3)                !   HII   fraction
  if(isHe) U(1,iUxHeII)=n_Spec(6)/(nH_com/aexp**3)      !   HeII  fraction
  if(isHe) U(1,iUxHeIII)=n_Spec(7)/(nH_com/aexp**3)     !   HeIII fraction
  U(1,iNp0:)=0.                              ! Photon densities and fluxes

  do while (aexp < aend)
     if(rt_UV_hom) call inp_UV_rates_table(1./aexp - 1., UVrates)

     daexp = dasura*aexp
     dt_cool = daexp                                                     &
             / (aexp*100.*h*3.2408608e-20)                               &
             / HsurH0(1.0/dble(aexp)-1.,omega0,omegaL,1.-omega0-omegaL)
     
     nH(1)  = nH_com/aexp**3
     U(1,1) = U(1,1)/aexp**2
     call rt_solve_cooling(U,dNpdt,dFpdt,nH,c_switch,Zsolar,dt_cool,aexp,1)

     U(1,1)=U(1,1)*aexp**2
     aexp = aexp + daexp
     if (if_write_result) write(*,'(4(1pe10.3))')                        &
                              aexp,nH(1),T2_com*mu/aexp**2,n_spec(1)/nH(1)
  end do
  T2end=U(1,1)/(aexp-daexp)**2
  ne=(n_spec(3)+(n_spec(5)+2.*n_spec(6))*0.25*Y/X)
end subroutine rt_evol_single_cell

!XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
FUNCTION HsurH0(z,omega0,omegaL,OmegaR)
!------------------------------------------------------------------------
  implicit none
  real(kind=8) :: HsurH0,z,omega0,omegaL,omegaR
!------------------------------------------------------------------------
  HsurH0=sqrt(Omega0*(1.d0+z)**3+OmegaR*(1.d0+z)**2+OmegaL)
END FUNCTION HsurH0

!=======================================================================
subroutine rt_cmp_metals(T2,nH,mu,metal_tot,metal_prime,aexp)
! Taken from the equilibrium cooling_module of RAMSES
! Compute cooling enhancement due to metals
! T2           => Temperature in Kelvin, divided by mu
! nH           => Hydrogen number density (H/cc)
! mu           => Average mass per particle in terms of mH
! metal_tot   <=  Metal cooling contribution to de/dt [erg s-1 cm-3]
! metal_prime <=  d(metal_tot)/dT2 [erg s-1 cm-3 K-1]
!=======================================================================
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
  real(dp),dimension(1:91),parameter :: excess_cooling_cc07 = (/         &
       & -24.9949,-24.7270,-24.0473,-23.0713,-22.2907,-21.8917,-21.8058, &
       & -21.8501,-21.9142,-21.9553,-21.9644,-21.9491,-21.9134,-21.8559, &
       & -21.7797,-21.6863,-21.5791,-21.4648,-21.3640,-21.2995,-21.2691, &
       & -21.2658,-21.2838,-21.2985,-21.2941,-21.2845,-21.2809,-21.2748, &
       & -21.2727,-21.3198,-21.4505,-21.5921,-21.6724,-21.6963,-21.6925, &
       & -21.6892,-21.7142,-21.7595,-21.7779,-21.7674,-21.7541,-21.7532, &
       & -21.7679,-21.7866,-21.8052,-21.8291,-21.8716,-21.9316,-22.0055, &
       & -22.0800,-22.1600,-22.2375,-22.3126,-22.3701,-22.4125,-22.4353, &
       & -22.4462,-22.4450,-22.4406,-22.4337,-22.4310,-22.4300,-22.4356, &
       & -22.4455,-22.4631,-22.4856,-22.5147,-22.5444,-22.5718,-22.5904, &
       & -22.6004,-22.5979,-22.5885,-22.5728,-22.5554,-22.5350,-22.5159, &
       & -22.4955,-22.4781,-22.4600,-22.4452,-22.4262,-22.4089,-22.3900, &
       & -22.3722,-22.3529,-22.3339,-22.3137,-22.2936,-22.2729,-22.2521 /)
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
