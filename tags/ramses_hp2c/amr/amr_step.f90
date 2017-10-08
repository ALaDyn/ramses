recursive subroutine amr_step(ilevel,icount)
  use amr_commons
  use pm_commons
  use hydro_commons
  use poisson_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel,icount
  !-------------------------------------------------------------------!
  ! This routine is the adaptive-mesh/adaptive-time-step main driver. !
  ! Each routine is called using a specific order, don't change it,   !
  ! unless you check all consequences first                           !
  !-------------------------------------------------------------------!
  integer::icycle,i,idim,ivar,info
  logical::ok_defrag
  logical,save::first_step=.true.

  if(numbtot(1,ilevel)==0)return

  if(verbose)write(*,999)icount,ilevel

  !-------------------------------------------
  ! Make new refinements and update boundaries
  !-------------------------------------------
  if(levelmin.lt.nlevelmax)then
     if(ilevel==levelmin.or.icount>1)then
        do i=ilevel,nlevelmax
           if(i>levelmin)then

              !--------------------------
              ! Build communicators
              !--------------------------
              call build_comm(i)

              !--------------------------
              ! Update boundaries
              !--------------------------
              call make_virtual_fine_int(cpu_map(1),i)
              if(hydro)then
#ifdef SOLVERmhd
                 do ivar=1,nvar+3
#else
                 do ivar=1,nvar
#endif
                    call make_virtual_fine_dp(uold(1,ivar),i)
                 end do
                 if(simple_boundary)call make_boundary_hydro(i)
                 if(poisson)then
                    do idim=1,ndim
                       call make_virtual_fine_dp(f(1,idim),i)
                    end do
                    if(simple_boundary)call make_boundary_force(i)
                 end if
              end if
           end if

           !--------------------------
           ! Refine grids
           !--------------------------
           call refine_fine(i)
        end do
     end if
  end if

  !--------------------------
  ! Load balance
  !--------------------------
  ok_defrag=.false.
  if(levelmin.lt.nlevelmax)then
     if(ilevel==levelmin)then
        if(nremap>0)then
           ! Skip first load balance because it has been performed before file dump
           if(nrestart>0.and.first_step)then
              first_step=.false.
           else
              if(MOD(nstep_coarse,nremap)==0)then
                 call load_balance
                 call defrag
                 ok_defrag=.true.
              endif
           end if
        end if
     endif
  end if

  !-----------------
  ! Particle leakage
  !-----------------
  if(pic)call make_tree_fine(ilevel)

  !------------------------
  ! Output results to files
  !------------------------
  if(ilevel==levelmin)then
     if(mod(nstep_coarse,foutput)==0.or.aexp>=aout(iout).or.t>=tout(iout))then
        if(.not.ok_defrag)then
           call defrag
        endif
        call dump_all
     endif
 
    ! Dump lightcone
     if(lightcone) then
        call output_cone()
     end if

!     ! Dump movie frame
!     if(movie) then
!        call output_frame()
!     end if

  endif

  !-----------------------------------------------------------
  ! Put here all stuffs that are done only at coarse time step
  !-----------------------------------------------------------
  if(ilevel==levelmin)then
     !----------------------------------------------------
     ! Kinetic feedback from giant molecular clouds
     !----------------------------------------------------
     if(hydro.and.star.and.eta_sn>0.and.f_w>0)call kinetic_feedback
     
     !-----------------------------------------------------
     ! Create sink particles and associated cloud particles
     !-----------------------------------------------------
     if(sink)call create_sink
  endif

  !--------------------
  ! Poisson source term
  !--------------------
  if(poisson)call rho_fine(ilevel,icount)

  !-------------------------------------------
  ! Sort particles between ilevel and ilevel+1
  !-------------------------------------------
  if(pic)then
     ! Remove particles to finer levels
     call kill_tree_fine(ilevel)
     ! Update boundary conditions for remaining particles
     call virtual_tree_fine(ilevel)
  end if

  !---------------
  ! Gravity update
  !---------------
  if(poisson)then
 
     ! Synchronize hydro for gravity (first pass)
     if(hydro)then
        if(nordlund_fix)then
           call synchro_hydro_fine(ilevel,-1.0*dtnew(ilevel))
        else
           call synchro_hydro_fine(ilevel,-0.5*dtnew(ilevel))
        endif
     endif

     ! Compute gravitational potential
     if(ilevel>levelmin)then
        if(ilevel .ge. cg_levelmin) then
           call phi_fine_cg(ilevel,icount)
        else
           call multigrid_fine(ilevel)
        end if
     else
        call multigrid_fine(levelmin)
     end if

     ! Compute gravitational acceleration
     call force_fine(ilevel)

     ! Thermal feedback from stars
     if(hydro.and.star.and.eta_sn>0)call thermal_feedback(ilevel)

     ! Synchronize remaining particles for gravity
     if(pic)then
        call synchro_fine(ilevel)
     end if

     if(hydro)then

        ! Synchronize hydro for gravity (second pass)
        if(nordlund_fix)then
           call synchro_hydro_fine(ilevel,+1.0*dtnew(ilevel))
        else
           call synchro_hydro_fine(ilevel,+0.5*dtnew(ilevel))
        endif

        ! Density threshold and/or Bondi accretion onto sink particle
        if(sink)then
!           call grow_jeans(ilevel)
           if(bondi)call grow_bondi(ilevel)
        endif

        ! Update boundaries
#ifdef SOLVERmhd
        do ivar=1,nvar+3
#else
        do ivar=1,nvar
#endif
           call make_virtual_fine_dp(uold(1,ivar),ilevel)
        end do
        if(simple_boundary)call make_boundary_hydro(ilevel)
     end if

  end if

  !----------------------
  ! Compute new time step
  !----------------------
  call newdt_fine(ilevel)
  if(ilevel>levelmin)then
     dtnew(ilevel)=MIN(dtnew(ilevel-1)/real(nsubcycle(ilevel-1)),dtnew(ilevel))
  end if

  ! Set unew equal to uold
  if(hydro)call set_unew(ilevel)

  !---------------------------
  ! Recursive call to amr_step
  !---------------------------
  if(ilevel<nlevelmax)then
     if(numbtot(1,ilevel+1)>0)then
        if(nsubcycle(ilevel)==2)then
           call amr_step(ilevel+1,1)
           call amr_step(ilevel+1,2)
        else
           call amr_step(ilevel+1,1)
        endif
     else 
        ! Otherwise, update time and finer level time-step
        dtold(ilevel+1)=dtnew(ilevel)/dble(nsubcycle(ilevel))
        dtnew(ilevel+1)=dtnew(ilevel)/dble(nsubcycle(ilevel))
        call update_time(ilevel)
     end if
  else
     call update_time(ilevel)
  end if

  !---------------
  ! Move particles
  !---------------
  if(pic)then
     call move_fine(ilevel) ! Only remaining particles
  end if

  !-----------
  ! Hydro step
  !-----------
  if(hydro)then

     ! Hyperbolic solver
     call godunov_fine(ilevel)

     ! Reverse update boundaries
#ifdef SOLVERmhd
     do ivar=1,nvar+3
#else
     do ivar=1,nvar
#endif
        call make_virtual_reverse_dp(unew(1,ivar),ilevel)
     end do
     if(pressure_fix)then
        call make_virtual_reverse_dp(enew(1),ilevel)
        call make_virtual_reverse_dp(divu(1),ilevel)
     endif

     ! Set uold equal to unew
     call set_uold(ilevel)

     ! Gravity source term
     if(poisson)call synchro_hydro_fine(ilevel,dtnew(ilevel))

     ! Restriction operator
     call upload_fine(ilevel)

     ! Cooling source term in leaf cells only
     if(cooling.or.T2_star>0.0)call cooling_fine(ilevel)

     ! Star formation in leaf cells only
     if(star)call star_formation(ilevel)

     ! Compute Bondi-Hoyle accretion parameters
     if(sink.and.bondi)call bondi_hoyle(ilevel)

     ! Update boundaries 
#ifdef SOLVERmhd
     do ivar=1,nvar+3
#else
     do ivar=1,nvar
#endif
        call make_virtual_fine_dp(uold(1,ivar),ilevel)
     end do
     if(simple_boundary)call make_boundary_hydro(ilevel)

     ! Magnetic diffusion step
#ifdef SOLVERmhd
     if(eta_mag>0d0.and.ilevel==levelmin)then
        call diffusion
     endif
#endif
  end if

  !-----------------------
  ! Compute refinement map
  !-----------------------
  call flag_fine(ilevel,icount)

  !----------------------------
  ! Merge finer level particles
  !----------------------------
  if(pic)call merge_tree_fine(ilevel)

  !-------------------------------
  ! Update coarser level time-step
  !-------------------------------
  if(ilevel>levelmin)then
     if(nsubcycle(ilevel-1)==1)dtnew(ilevel-1)=dtnew(ilevel)
     if(icount==2)dtnew(ilevel-1)=dtold(ilevel)+dtnew(ilevel)
  end if

999 format(' Entering amr_step',i1,' for level',i2)

end subroutine amr_step



