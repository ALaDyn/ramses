subroutine update_time(ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  use cooling_module
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif  
  integer::ilevel

  real(dp)::dt,econs,mcons
  real(kind=8)::ttend
  real(kind=8),save::ttstart=0
  integer::i,itest,info

  ! Local constants
  dt=dtnew(ilevel)
  itest=0

#ifndef WITHOUTMPI
  if(myid==1)then
     if(ttstart.eq.0.0)ttstart=MPI_WTIME(info)
  endif
#endif

  !-------------------------------------------------------------
  ! At this point, IF nstep_coarse has JUST changed, all levels
  ! are synchronised, and all new refinements have been done.
  !-------------------------------------------------------------
  if(nstep_coarse .ne. nstep_coarse_old)then

     !--------------------------
     ! Check mass conservation
     !--------------------------
     if(mass_tot_0==0.0D0)then
        mass_tot_0=mass_tot
        mcons=0.0D0
     else
        mcons=(mass_tot-mass_tot_0)/mass_tot_0
     end if

     !----------------------------
     ! Check energy conservation
     !----------------------------
     if(epot_tot_old.ne.0)then
        epot_tot_int=epot_tot_int + &
             & 0.5D0*(epot_tot_old+epot_tot)*log(aexp/aexp_old)
     end if
     epot_tot_old=epot_tot
     aexp_old=aexp
     if(const==0.0D0)then
        const=epot_tot+ekin_tot  ! initial total energy
        econs=0.0D0
     else
        econs=(ekin_tot+epot_tot-epot_tot_int-const) / &
             &(-(epot_tot-epot_tot_int-const)+ekin_tot)
     end if

     if(mod(nstep_coarse,ncontrol)==0.or.output_done)then
        if(myid==1)then
           
           !-------------------------------
           ! Output AMR structure to screen
           !-------------------------------
           write(*,*)'Mesh structure'
           do i=1,nlevelmax
              if(numbtot(1,i)>0)write(*,999)i,numbtot(1:4,i)
           end do
           
           !----------------------------------------------
           ! Output mass and energy conservation to screen
           !----------------------------------------------
           if(scheme.eq.'induction')then
#ifdef SOLVERmhd
              write(*,778)nstep_coarse,econs,epot_tot,ekin_tot,emag_tot
#endif
           else if(cooling.or.pressure_fix)then
              write(*,778)nstep_coarse,econs,epot_tot,ekin_tot,eint_tot
           else
              write(*,777)nstep_coarse,mcons,econs,epot_tot,ekin_tot
           end if
           if(pic)then
              write(*,888)nstep,t,dt,aexp,&
                   & real(100.0D0*dble(used_mem_tot)/dble(ngridmax+1)),&
                   & real(100.0D0*dble(npartmax-numbp_free_tot)/dble(npartmax+1))
           else
              write(*,888)nstep,t,dt,aexp,&
                   & real(100.0D0*dble(used_mem_tot)/dble(ngridmax+1))
           endif
           itest=1
        end if
        output_done=.false.
     end if

     !---------------
     ! Exit program
     !---------------
     if(t>=tout(noutput).or.aexp>=aout(noutput).or. &
          & nstep_coarse>=nstepmax)then
        if(myid==1)then
           write(*,*)'Run completed'
#ifndef WITHOUTMPI
           ttend=MPI_WTIME(info)
           write(*,*)'Total elapsed time:',ttend-ttstart
#endif
        endif
        call clean_stop
     end if

  end if
  nstep_coarse_old=nstep_coarse

  !----------------------------
  ! Output controls to screen
  !----------------------------
  if(mod(nstep,ncontrol)==0)then
     if(myid==1.and.itest==0)then
        if(pic)then
           write(*,888)nstep,t,dt,aexp,&
                & real(100.0D0*dble(used_mem_tot)/dble(ngridmax+1)),&
                & real(100.0D0*dble(npartmax-numbp_free_tot)/dble(npartmax+1))
        else
           write(*,888)nstep,t,dt,aexp,&
                & real(100.0D0*dble(used_mem_tot)/dble(ngridmax+1))
        endif
     end if
  end if

  !------------------------
  ! Update time variables
  !------------------------
  t=t+dt
  nstep=nstep+1
  if(cosmo)then
     ! Find neighboring times
     i=1
     do while(tau_frw(i)>t.and.i<n_frw)
        i=i+1
     end do
     ! Interpolate expansion factor
     aexp = aexp_frw(i  )*(t-tau_frw(i-1))/(tau_frw(i  )-tau_frw(i-1))+ &
          & aexp_frw(i-1)*(t-tau_frw(i  ))/(tau_frw(i-1)-tau_frw(i  ))
     hexp = hexp_frw(i  )*(t-tau_frw(i-1))/(tau_frw(i  )-tau_frw(i-1))+ &
          & hexp_frw(i-1)*(t-tau_frw(i  ))/(tau_frw(i-1)-tau_frw(i  ))
  end if

777 format(' Main step=',i6,' mcons=',1pe9.2,' econs=',1pe9.2, &
         & ' epot=',1pe9.2,' ekin=',1pe9.2)
778 format(' Main step=',i6,' econs=',1pe9.2, &
         & ' epot=',1pe9.2,' ekin=',1pe9.2,' eint=',1pe9.2)
888 format(' Fine step=',i6,' t=',1pe12.5,' dt=',1pe10.3, &
         & ' a=',1pe10.3,' mem=',0pF4.1,'% ',0pF4.1,'%')
999 format(' Level ',I2,' has ',I10,' grids (',3(I8,','),')')
 
end subroutine update_time
  
subroutine clean_stop
  use amr_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::info
#ifndef WITHOUTMPI
  call MPI_FINALIZE(info)
#endif
  stop
end subroutine clean_stop

subroutine writemem(usedmem)
  real::usedmem
  integer::getpagesize

#ifdef NOSYSTEM
!  call PXFSYSCONF(_SC_PAGESIZE,ipagesize,ierror)
  ipagesize=4096
#else
!  ipagesize = getpagesize()
  ipagesize=4096
#endif
  usedmem=dble(usedmem)*dble(ipagesize)

  if(usedmem>1024.**3.)then
     write(*,999)usedmem/1024.**3.
  else if (usedmem>1024.**2.) then
     write(*,998)usedmem/1024.**2
  else if (usedmem>1024.) then
     write(*,997)usedmem/1024.
  endif

997 format(' Used memory:',F5.1,' kb')
998 format(' Used memory:',F5.1,' Mb')
999 format(' Used memory:',F5.1,' Gb')

end subroutine writemem

subroutine getmem(outmem)
  real::outmem
  character(len=300) :: dir, dir2,  cmd, file
  file='/proc/self/stat'
  open(unit=1,file=file,form='formatted')
  read(1,'(A300)')dir
  close(1)
  ind=300
  j=0
  do while (j<23)
     ind=index(dir,' ')
     dir2=dir(ind+1:300)
     j=j+1
     dir=dir2
  end do
  ind=index(dir,' ')
  dir2=dir(1:ind)
  read(dir2,'(I12)')nmem

  outmem=dble(nmem)

end subroutine getmem






