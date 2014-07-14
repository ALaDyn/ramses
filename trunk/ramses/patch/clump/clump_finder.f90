subroutine clump_finder(create_output)
  use amr_commons
  use poisson_commons, ONLY:phi,rho
  use clfind_commons
  use hydro_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  logical::create_output

  !----------------------------------------------------------------------------
  ! Description of clump_finder:
  ! The clumpfinder detect first all cells having a density above
  ! a given threshold. These cells are linked to their densest neighbors,
  ! defining a peak patch around each local density maximum. 
  ! If a so called peak patch is considered irrelevant, it is merged to its 
  ! neighboring peak patch with the highest saddle density.
  ! Parameters are read in a namelist and they are:
  ! - density_threshold: defines the cell population to consider
  ! - relevance_threshold: merge peaks that are considered as ``noise''
  ! - saddle_threshold: for cosmo runs, merge peaks into halos (HOP-style)
  ! - mass_threshold: output only clumps (or halos) above this mass
  ! Andreas Bleuler & Davide Martizzi & Romain Teyssier
  !----------------------------------------------------------------------------

  integer::itest,istep,nskip,ilevel,info,icpu,nmove,nmove_all,nzero,nzero_all
  integer::i,j,ntest,ntest_all,peak_nr
  integer,dimension(1:ncpu)::ntest_cpu,ntest_cpu_all
  integer,dimension(1:ncpu)::npeaks_per_cpu_tot
  logical::all_bound

  if(verbose.and.myid==1)write(*,*)' Entering clump_finder'

  !---------------------------------------------------------------
  ! Compute rho from gas density or dark matter particles
  !---------------------------------------------------------------
  if(ivar_clump==0)then
     do ilevel=levelmin,nlevelmax
        if(pic)call make_tree_fine(ilevel)
        if(poisson)call rho_fine(ilevel,2)
        if(pic)then
           call kill_tree_fine(ilevel)
           call virtual_tree_fine(ilevel)
        endif
     end do
     do ilevel=nlevelmax,levelmin,-1
        if(pic)call merge_tree_fine(ilevel)
     end do
  endif

  !------------------------------------------------------------------------
  ! count the number of cells with density above the threshold
  ! flag the cells, share info across processors
  !------------------------------------------------------------------------
  ntest=0
  do ilevel=levelmin,nlevelmax
     if(ivar_clump==0)then ! action 1: count and flag
        call count_test_particle(rho(1),ilevel,ntest,0,1) 
     else
        if(hydro)then      ! action 1: count and flag
           call count_test_particle(uold(1,ivar_clump),ilevel,ntest,0,1)
        endif
     end if
  end do
  ntest_cpu=0; ntest_cpu_all=0
  ntest_cpu(myid)=ntest
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ntest_cpu,ntest_cpu_all,ncpu,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
  ntest_cpu(1)=ntest_cpu_all(1)
#endif
  do icpu=2,ncpu
     ntest_cpu(icpu)=ntest_cpu(icpu-1)+ntest_cpu_all(icpu)
  end do
  ntest_all=ntest_cpu(ncpu)
  if(myid==1)then
     if(ntest_all.gt.0.and.clinfo)then
        write(*,'(" Total number of cells above threshold=",I10)')ntest_all
     endif
  end if

  !------------------------------------------------------------------------
  ! Allocate arrays and create list of cells above the threshold
  !------------------------------------------------------------------------
  if (ntest>0) then 
     allocate(denp(ntest),levp(ntest),imaxp(ntest),icellp(ntest))
     denp=0.d0; levp=0; imaxp=0; icellp=0
  endif
  itest=0
  nskip=ntest_cpu(myid)-ntest
  do ilevel=levelmin,nlevelmax
     if(ivar_clump==0)then
        call count_test_particle(rho(1),ilevel,itest,nskip,2)
     else
        if(hydro)then
           call count_test_particle(uold(1,ivar_clump),ilevel,itest,nskip,2)
        endif
     endif
  end do
  do ilevel=nlevelmax,levelmin,-1
     call make_virtual_fine_int(flag2(1),ilevel)
  end do

  !-----------------------------------------------------------------------
  ! Sort cells above threshold according to their density
  !-----------------------------------------------------------------------
  if (ntest>0) then
     allocate(testp_sort(ntest)) 
     do i=1,ntest
        denp(i)=-denp(i)
        testp_sort(i)=i
     end do
     call quick_sort_dp(denp(1),testp_sort(1),ntest) 
     deallocate(denp)
  endif

  !-----------------------------------------------------------------------
  ! Count number of density peaks and share info across processors 
  !-----------------------------------------------------------------------
  npeaks=0; nmove=0; nzero=0
  if(ntest>0)then
     if(ivar_clump==0)then  ! case 1: count peaks
        call scan_for_peaks(rho(1),ntest,npeaks,nzero,1)
     else
        if(hydro)then       ! case 1: count peaks
           call scan_for_peaks(uold(1,ivar_clump),ntest,npeaks,nzero,1)
        endif
     endif
  endif
  allocate(npeaks_per_cpu(1:ncpu))
  allocate(ipeak_start(1:ncpu))
  npeaks_per_cpu=0
  npeaks_per_cpu(myid)=npeaks
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(npeaks_per_cpu,npeaks_per_cpu_tot,ncpu,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  npeaks_per_cpu_tot=npeaks_per_cpu
#endif
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(npeaks,npeaks_tot,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  npeaks_tot=npeaks
#endif
  if (myid==1.and.npeaks_tot>0.and.clinfo) &
       & write(*,'(" Total number of density peaks found=",I10)')npeaks_tot
  
  !----------------------------------------------------------------------
  ! Determine peak-ids positions for each cpu
  !----------------------------------------------------------------------
  ipeak_start=0
  npeaks_per_cpu=npeaks_per_cpu_tot
  do icpu=2,ncpu
     ipeak_start(icpu)=ipeak_start(icpu-1)+npeaks_per_cpu(icpu-1)
  end do
  peak_nr=ipeak_start(myid)

  !----------------------------------------------------------------------
  ! Flag peaks with global peak id using flag2 array
  ! Compute peak density using max_dens array
  !----------------------------------------------------------------------
  nmove=0
  nskip=peak_nr
  if(npeaks>0)then
     ! Compute the size of the peak-based arrays
     npeaks_max=4*npeaks
     ! A better strategy would be to take the max over all CPUs ?
     allocate(max_dens(npeaks_max))
     max_dens=0.
  endif
  flag2=0
  if(ntest>0)then
     if(ivar_clump==0)then  ! case 2: flag peaks
        call scan_for_peaks(rho(1),ntest,nskip,nzero,2)
     else
        if(hydro)then       ! case 2: flag peaks
           call scan_for_peaks(uold(1,ivar_clump),ntest,nskip,nzero,2)
        endif
     endif
  endif
  do ilevel=nlevelmax,levelmin,-1
     call make_virtual_fine_int(flag2(1),ilevel)
  end do

  !---------------------------------------------------------------------
  ! Determine peak-patches around each peak
  ! Main step: 
  ! - order cells in descending density
  ! - get peak id from densest neighbor
  ! - nmove is number of peak id's passed along
  ! - done when nmove=0 (for single core, only one sweep is necessary)
  !---------------------------------------------------------------------
  if (myid==1.and.ntest_all>0.and.clinfo)write(*,*)'Finding peak patches'
  nmove=1
  istep=0
  do while (nmove.gt.0)
     nmove=0
     nzero=0
     nskip=peak_nr
     if(ntest>0)then
        if(ivar_clump==0)then
           call scan_for_peaks(rho(1),ntest,nmove,nzero,3)
        else
           if(hydro)then
              call scan_for_peaks(uold(1,ivar_clump),ntest,nmove,nzero,3)
           endif
        endif
     endif
     do ilevel=nlevelmax,levelmin,-1
        call make_virtual_fine_int(flag2(1),ilevel)
     end do
     istep=istep+1
#ifndef WITHOUTMPI 
     call MPI_ALLREDUCE(nmove,nmove_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
     nmove=nmove_all
     call MPI_ALLREDUCE(nzero,nzero_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
     nzero=nzero_all
#endif   
     if(myid==1.and.ntest_all>0.and.clinfo)write(*,*)"istep=",istep,"nmove=",nmove
  end do

  !------------------------------------
  ! Allocate peak-patch property arrays
  !------------------------------------
  call allocate_peak_patch_arrays(ntest)
  call build_peak_communicator

  if(npeaks_tot > 0)then
     !------------------------------------------
     ! Compute the saddle point density matrix
     !------------------------------------------
     if(ivar_clump==0)then
        call saddlepoint_search(rho(1),ntest) 
     else
        if(hydro)then
           call saddlepoint_search(uold(1,ivar_clump),ntest)
        endif
     endif
     call build_peak_communicator

     !------------------------------------------
     ! Merge irrelevant peaks
     !------------------------------------------
     if(myid==1.and.clinfo)write(*,*)"Now merging irrelevant peaks."
     call merge_clumps(ntest,'relevance')
     do ilevel=nlevelmax,levelmin,-1
        call make_virtual_fine_int(flag2(1),ilevel)
     end do

     !------------------------------------------
     ! Compute clumps properties
     !------------------------------------------
     if(myid==1.and.clinfo)write(*,*)"Computing relevant clump properties."
     if(ivar_clump==0)then
        call compute_clump_properties(rho(1),ntest)
     else
        if(hydro)then
           call compute_clump_properties(uold(1,ivar_clump),ntest)
        endif
     endif
     
     !------------------------------------------
     ! Merge clumps into haloes
     !------------------------------------------
     if(saddle_threshold>0)then
        if(myid==1.and.clinfo)write(*,*)"Now merging peaks into halos."
        call merge_clumps(ntest,'saddleden')
     endif

     !------------------------------------------
     ! Output clumps properties to file
     !------------------------------------------
     if(myid==1.and.clinfo)then
        write(*,*)"Output status of peak memory."
     endif
     if(clinfo)call analyze_peak_memory
     
     if(create_output)then
        if(myid==1)write(*,*)"Outputing clump properties to disc."
        call write_clump_properties(.true.)
     endif

  end if

  if(myid==1)write(*,*)'Clump finding completed.'
  stop

  ! Deallocate test particle and peak arrays
  if (ntest>0)then
     deallocate(icellp)
     deallocate(levp)
     deallocate(testp_sort)
     deallocate(imaxp)
  endif
  call deallocate_all

end subroutine clump_finder
!################################################################
!################################################################
!################################################################
!################################################################
subroutine count_test_particle(xx,ilevel,ntot,nskip,action)
  use amr_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel,ntot,nskip,action
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx

  !----------------------------------------------------------------------
  ! Description: This routine loops over all cells above and checks wether
  ! their density lies above the threshold. If so:
  ! case 1: count the new test particles and flag the cell
  ! case 2: create the test particle
  ! xx is on input the array containing the density field
  !----------------------------------------------------------------------

  integer ::ncache,ngrid
  integer ::igrid,ind,i,iskip
  integer ,dimension(1:nvector)::ind_grid,ind_cell
  logical ,dimension(1:nvector)::ok

  if(numbtot(1,ilevel)==0) return

  if(verbose .and. myid==1)then
     write(*,*)' Entering count test particle for level=',& 
          & ilevel,' and action=',action
  endif

  ! Loop over grids
  ncache=active(ilevel)%ngrid
  do igrid=1,ncache,nvector
     ngrid=MIN(nvector,ncache-igrid+1)
     do i=1,ngrid
        ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
     end do
     ! loop over cells
     do ind=1,twotondim
        iskip=ncoarse+(ind-1)*ngridmax
        do i=1,ngrid
           ind_cell(i)=iskip+ind_grid(i)
        end do

        !checks
        do i=1,ngrid
           ok(i)=son(ind_cell(i))==0 !check if leaf cell
           ok(i)=ok(i).and.xx(ind_cell(i))>density_threshold !check density
        end do

        select case (action) 
        case (1) !count and flag
           ! Compute test particle map
           do i=1,ngrid
              flag2(ind_cell(i))=0
              if(ok(i))then
                 flag2(ind_cell(i))=1 
                 ntot=ntot+1
              endif
           end do
        case(2) !create 'testparticles'
           do i=1,ngrid
              if (ok(i))then
                 ntot=ntot+1                    ! Local test particle index
                 levp(ntot)=ilevel              ! Level
                 flag2(ind_cell(i))=ntot+nskip  ! Initialize flag2 to GLOBAL test particle index
                 icellp(ntot)=ind_cell(i)       ! Local cell index
                 denp(ntot)=xx(ind_cell(i)) ! Save density values here!
              end if
           end do
        end select
     end do
  end do

end subroutine count_test_particle
!################################################################
!################################################################
!################################################################
!################################################################
subroutine scan_for_peaks(xx,npartt,n,nzero,action)
  use amr_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h' 
#endif
  integer::npartt,n,nzero,action
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  !----------------------------------------------------------------------
  ! vectorization of the neighborsearch for the action cases
  ! 1: count the peaks (no denser neighbor)
  ! 2: count and flag peaks with global peak index number
  ! 3: get global clump index from densest neighbor
  !----------------------------------------------------------------------
  integer::ilevel,next_level,ipart,jpart,ip
  integer,dimension(1:nvector)::ind_part,ind_cell,ind_max
  logical,save::first_pass=.true.

  if(.not. first_pass)then
     select case (action)
     case (1)   ! Count peaks  
        do ipart=1,npartt
           jpart=testp_sort(ipart)
           if(imaxp(jpart).EQ.-1)n=n+1
        end do
     case (2)   ! Initialize flag2 to peak global index
        do ipart=1,npartt
           jpart=testp_sort(ipart)
           if(imaxp(jpart).EQ.-1)then
              n=n+1
              flag2(icellp(jpart))=n
              max_dens(n-ipeak_start(myid))=xx(icellp(jpart))
           endif
        end do
     case (3) ! Propagate flag2
        do ipart=1,npartt
           jpart=testp_sort(ipart)
           if(imaxp(jpart).NE.-1)then
              if(flag2(icellp(jpart)).ne.flag2(imaxp(jpart)))n=n+1
              flag2(icellp(jpart))=flag2(imaxp(jpart))
              if(flag2(icellp(jpart)).eq.0)nzero=nzero+1
           endif
        end do
     end select
     return
  endif

  ip=0
  do ipart=1,npartt
     ip=ip+1
     ilevel=levp(testp_sort(ipart)) ! level
     next_level=0 !level of next particle
     if(ipart<npartt)next_level=levp(testp_sort(ipart+1))
     ind_cell(ip)=icellp(testp_sort(ipart))
     ind_part(ip)=testp_sort(ipart)
     if(ip==nvector .or. next_level /= ilevel)then
        call neighborsearch(xx(1),ind_cell,ind_max,ip,n,nzero,ilevel,action)
        do jpart=1,ip
           imaxp(ind_part(jpart))=ind_max(jpart)
        end do
        ip=0
     endif
  end do
  if (ip>0)then
     call neighborsearch(xx(1),ind_cell,ind_max,ip,n,nzero,ilevel,action)
     do jpart=1,ip
        imaxp(ind_part(jpart))=ind_max(jpart)
     end do
  endif

  first_pass=.false.

end subroutine scan_for_peaks
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine saddlepoint_search(xx,ntest)
  use amr_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ntest
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  !---------------------------------------------------------------------------
  ! subroutine which creates a npeaks**2 sized array of saddlepoint densities
  ! by looping over all testparticles and passing them to neighborcheck with
  ! case 4, which means that saddlecheck will be called for each neighboring
  ! leaf cell. There it is checked, whether the two cells (original cell and
  ! neighboring cell) are connected by a new densest saddle.
  !---------------------------------------------------------------------------
  integer::ipart,ip,ilevel,next_level
  integer::i,j,info,dummyint,dummyzero
  integer,dimension(1:nvector)::ind_cell,ind_max

  ip=0
  do ipart=1,ntest
     ip=ip+1
     ilevel=levp(testp_sort(ipart)) ! level
     next_level=0 !level of next particle
     if(ipart<ntest)next_level=levp(testp_sort(ipart+1))
     ind_cell(ip)=icellp(testp_sort(ipart))
     if(ip==nvector .or. next_level /= ilevel)then
        call neighborsearch(xx(1),ind_cell,ind_max,ip,dummyint,dummyzero,ilevel,4)
        ip=0
     endif
  end do
  if (ip>0)call neighborsearch(xx(1),ind_cell,ind_max,ip,dummyint,dummyzero,ilevel,4)

end subroutine saddlepoint_search
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine neighborsearch(xx,ind_cell,ind_max,np,count,count_zero,ilevel,action)
  use amr_commons
  use clfind_commons,ONLY:max_dens,ipeak_start
  implicit none
  integer::np,count,count_zero,ilevel,action
  integer,dimension(1:nvector)::ind_max,ind_cell
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx

  !------------------------------------------------------------
  ! This routine constructs all neighboring leaf cells at levels 
  ! ilevel-1, ilevel, ilevel+1.
  ! Depending on the action case value, fuctions performing
  ! further checks for the neighbor cells are called.
  ! xx is on input the array containing the density field  
  !------------------------------------------------------------

  integer::j,ind,nx_loc,i1,j1,k1,i2,j2,k2,i3,j3,k3,ix,iy,iz
  integer::i1min,i1max,j1min,j1max,k1min,k1max
  integer::i2min,i2max,j2min,j2max,k2min,k2max
  integer::i3min,i3max,j3min,j3max,k3min,k3max
  real(dp)::dx,dx_loc,scale,vol_loc
  integer ,dimension(1:nvector)::cell_index,cell_levl,clump_nr,indv,ind_grid
  real(dp),dimension(1:twotondim,1:3)::xc
  real(dp),dimension(1:nvector,1:ndim)::xtest
  real(dp),dimension(1:nvector)::density_max
  real(dp),dimension(1:3)::skip_loc
  logical ,dimension(1:nvector)::okpeak,ok

#if NDIM==3
  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**3

  ! Integer constants
  i1min=0; i1max=0; i2min=0; i2max=0; i3min=0; i3max=0
  j1min=0; j1max=0; j2min=0; j2max=0; j3min=0; j3max=0
  k1min=0; k1max=0; k2min=0; k2max=0; k3min=0; k3max=0
  if(ndim>0)then
     i1max=1; i2max=2; i3max=3
  end if
  if(ndim>1)then
     j1max=1; j2max=2; j3max=3
  end if
  if(ndim>2)then
     k1max=1; k2max=2; k3max=3
  end if

  ! Cells center position relative to grid center position
  do ind=1,twotondim
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     xc(ind,1)=(dble(ix)-0.5D0)*dx
     xc(ind,2)=(dble(iy)-0.5D0)*dx
     xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do
  
  ! some preliminary action...
  do j=1,np
     indv(j)=(ind_cell(j)-ncoarse-1)/ngridmax+1 ! cell position in grid
     ind_grid(j)=ind_cell(j)-ncoarse-(indv(j)-1)*ngridmax ! grid index
     density_max(j)=xx(ind_cell(j))*1.0001 ! get cell density (1.0001 probably not necessary)
     ind_max(j)=ind_cell(j) !save cell index   
     if (action.ge.4)clump_nr(j)=flag2(ind_cell(j)) ! save clump number
  end do
  
  ! initialze logical array
  okpeak=.true.

  !================================
  ! generate neighbors level ilevel-1
  !================================
  if(ilevel>levelmin)then
     ! Generate 2x2x2 neighboring cells at level ilevel-1
     do k1=k1min,k1max
        do j1=j1min,j1max
           do i1=i1min,i1max
              ok=.false.
              do j=1,np
                 xtest(j,1)=(xg(ind_grid(j),1)+2*xc(indv(j),1)-skip_loc(1))*scale+(2*i1-1)*dx_loc
                 xtest(j,2)=(xg(ind_grid(j),2)+2*xc(indv(j),2)-skip_loc(2))*scale+(2*j1-1)*dx_loc
                 xtest(j,3)=(xg(ind_grid(j),3)+2*xc(indv(j),3)-skip_loc(3))*scale+(2*k1-1)*dx_loc
              end do
              call get_cell_index(cell_index,cell_levl,xtest,ilevel,np)
              do j=1,np 
                 ! check wether neighbor is in a leaf cell at the right level
                 if(son(cell_index(j))==0.and.cell_levl(j)==(ilevel-1))ok(j)=.true.
              end do     
              ! check those neighbors
              if (action<4)call peakcheck(xx(1),cell_index,okpeak,ok,density_max,ind_max,np)
              if (action==4)call saddlecheck(xx(1),ind_cell,cell_index,clump_nr,ok,np)
              if (action==5)call phi_ref_check(ind_cell,cell_index,clump_nr,ok,np)
           end do
        end do
     end do
  endif

  !================================
  ! generate neighbors at level ilevel
  !================================
  ! Generate 3x3x3 neighboring cells at level ilevel
  do k2=k2min,k2max
     do j2=j2min,j2max
        do i2=i2min,i2max
           ok=.false.
           do j=1,np
              xtest(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i2-1)*dx_loc
              xtest(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j2-1)*dx_loc
              xtest(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k2-1)*dx_loc
           end do
           call get_cell_index(cell_index,cell_levl,xtest,ilevel,np)
           do j=1,np
              ! check wether neighbor is in a leaf cell at the right level
              if(son(cell_index(j))==0.and.cell_levl(j)==ilevel)ok(j)=.true.
           end do
           ! check those neighbors
           if (action<4)call peakcheck(xx(1),cell_index,okpeak,ok,density_max,ind_max,np)
           if (action==4)call saddlecheck(xx(1),ind_cell,cell_index,clump_nr,ok,np)
           if (action==5)call phi_ref_check(ind_cell,cell_index,clump_nr,ok,np)
        end do
     end do
  end do

  !===================================
  ! generate neighbors at level ilevel+1
  !====================================
  if(ilevel<nlevelmax)then
     ! Generate 4x4x4 neighboring cells at level ilevel+1
     do k3=k3min,k3max
        do j3=j3min,j3max
           do i3=i3min,i3max
              ok=.false.
              do j=1,np
                 xtest(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i3-1.5)*dx_loc/2.0
                 xtest(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j3-1.5)*dx_loc/2.0
                 xtest(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k3-1.5)*dx_loc/2.0
              end do
              call get_cell_index(cell_index,cell_levl,xtest,ilevel+1,np)
              do j=1,np
                 ! check wether neighbor is in a leaf cell at the right level
                 if(son(cell_index(j))==0.and.cell_levl(j)==(ilevel+1))ok(j)=.true.
              end do
              ! check those neighbors
              if (action<4)call peakcheck(xx(1),cell_index,okpeak,ok,density_max,ind_max,np)
              if (action==4)call saddlecheck(xx(1),ind_cell,cell_index,clump_nr,ok,np)
              if (action==5)call phi_ref_check(ind_cell,cell_index,clump_nr,ok,np)
           end do
        end do
     end do
  endif


  !===================================
  ! choose action for different cases
  !====================================
  select case (action)
  case (1)   ! Count peaks  
     do j=1,np
        if(okpeak(j))then
           count=count+1
           ind_max(j)=-1
        endif
     end do  
  case (2)   ! Initialize flag2 to peak global index
     do j=1,np
        if(okpeak(j))then 
           count=count+1
           ind_max(j)=-1
           flag2(ind_cell(j))=count
           max_dens(count-ipeak_start(myid))=xx(ind_cell(j))
        end if
     end do
  case (3) ! Propagate flag2
     do j=1,np
        if(flag2(ind_cell(j)).ne.flag2(ind_max(j)))count=count+1
        flag2(ind_cell(j))=flag2(ind_max(j))
        if(flag2(ind_cell(j)).eq.0)count_zero=count_zero+1
        if(okpeak(j))ind_max(j)=-1
     end do
  end select

#endif

end subroutine neighborsearch
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine peakcheck(xx,cell_index,okpeak,ok,density_max,ind_max,np)
  use amr_commons
  implicit none
  !----------------------------------------------------------------------
  ! routine to check wether neighbor is denser or not
  !----------------------------------------------------------------------
  logical,dimension(1:nvector)::ok,okpeak
  integer,dimension(1:nvector)::cell_index,ind_max
  real(dp),dimension(1:nvector)::density_max
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  integer::np,j

  do j=1,np
     !check if neighboring cell is denser
     ok(j)=ok(j).and.xx(cell_index(j))>density_max(j)
  end do
  do j=1,np
     if(ok(j))then !so if there is a denser neighbor
        okpeak(j)=.false. !no peak
        density_max(j)=xx(cell_index(j)) !change densest neighbor dens
        ind_max(j)=cell_index(j) !change densest neighbor index
     endif
  end do

end subroutine peakcheck
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine saddlecheck(xx,ind_cell,cell_index,clump_nr,ok,np)
  use amr_commons
  use clfind_commons, ONLY: sparse_saddle_dens
  use sparse_matrix
  implicit none
  !----------------------------------------------------------------------
  ! routine to check wether neighbor is connected through new densest saddle
  !----------------------------------------------------------------------
  logical,dimension(1:nvector)::ok
  integer,dimension(1:nvector)::cell_index,clump_nr,ind_cell,neigh_cl
  real(dp),dimension(1:nvector)::av_dens
  real(dp),dimension(1:ncoarse+ngridmax*twotondim)::xx
  integer::np,j,ipeak,jpeak

  do j=1,np
     neigh_cl(j)=flag2(cell_index(j))!index of the clump the neighboring cell is in 
  end do
  do j=1,np
     ok(j)=ok(j).and. neigh_cl(j)/=0 !neighboring cell is in a clump
     ok(j)=ok(j).and. neigh_cl(j)/=clump_nr(j) !neighboring cell is in another clump
     av_dens(j)=(xx(cell_index(j))+xx(ind_cell(j)))*0.5 !average density of cell and neighbor cell
  end do
  do j=1,np
     if(ok(j))then ! if all criteria met, replace saddle density array value
        call get_local_peak_id(clump_nr(j),ipeak)
        call get_local_peak_id(neigh_cl(j),jpeak)
        if (get_value(ipeak,jpeak,sparse_saddle_dens) < av_dens(j))then
           call set_value(ipeak,jpeak,av_dens(j),sparse_saddle_dens)
        end if
        if (get_value(jpeak,ipeak,sparse_saddle_dens) < av_dens(j))then
           call set_value(jpeak,ipeak,av_dens(j),sparse_saddle_dens)
        end if
     end if
  end do

end subroutine saddlecheck
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine phi_ref_check(ind_cell,cell_index,clump_nr,ok,np)
  use amr_commons, ONLY:flag2,nvector,dp
  use clfind_commons, ONLY: phi_ref
  use poisson_commons, ONLY: phi
  implicit none
  !----------------------------------------------------------------------
  ! routine to check wether neighbor is connected through new densest saddle
  !----------------------------------------------------------------------
  logical,dimension(1:nvector)::ok
  integer,dimension(1:nvector)::cell_index,clump_nr,ind_cell,neigh_cl
  real(dp),dimension(1:nvector)::av_phi
  integer::np,j

  do j=1,np
     neigh_cl(j)=flag2(cell_index(j))!nuber of clump the neighboring cell is in 
  end do
  do j=1,np
     ok(j)=ok(j).and. clump_nr(j)>0 !check that cell is not in a clump that has been merged to zero
     ok(j)=ok(j).and. neigh_cl(j)/=clump_nr(j) !neighboring cell is in another clump (can be zero)
     av_phi(j)=(phi(cell_index(j))+phi(ind_cell(j)))*0.5 !average pot of cell and neighbor cell
  end do
  do j=1,np
     if(ok(j))then ! if criteria met, reference potential for clump
        phi_ref(clump_nr(j))=min(av_phi(j),phi_ref(clump_nr(j)))
     end if
  end do

end subroutine phi_ref_check
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine get_cell_index(cell_index,cell_levl,xpart,ilevel,n)
  use amr_commons
  implicit none

  integer::n,ilevel
  integer,dimension(1:nvector)::cell_index,cell_levl
  real(dp),dimension(1:nvector,1:3)::xpart

  !----------------------------------------------------------------------------
  ! This routine returns the index and level of the cell, (at maximum level
  ! ilevel), in which the input the position specified by xpart lies
  !----------------------------------------------------------------------------

  real(dp)::xx,yy,zz
  integer::i,j,ii,jj,kk,ind,iskip,igrid,ind_cell,igrid0

  if ((nx.eq.1).and.(ny.eq.1).and.(nz.eq.1)) then
  else if ((nx.eq.3).and.(ny.eq.3).and.(nz.eq.3)) then
  else
     write(*,*)"nx=ny=nz != 1,3 is not supported."
     call clean_stop
  end if

  ind_cell=0
  igrid0=son(1+icoarse_min+jcoarse_min*nx+kcoarse_min*nx*ny)
  do i=1,n
     xx = xpart(i,1)/boxlen + (nx-1)/2.0
     yy = xpart(i,2)/boxlen + (ny-1)/2.0
     zz = xpart(i,3)/boxlen + (nz-1)/2.0

     if(xx<0.)xx=xx+dble(nx)
     if(xx>dble(nx))xx=xx-dble(nx)
     if(yy<0.)yy=yy+dble(ny)
     if(yy>dble(ny))yy=yy-dble(ny)
     if(zz<0.)zz=zz+dble(nz)
     if(zz>dble(nz))zz=zz-dble(nz)

     igrid=igrid0
     do j=1,ilevel 
        ii=1; jj=1; kk=1
        if(xx<xg(igrid,1))ii=0
        if(yy<xg(igrid,2))jj=0
        if(zz<xg(igrid,3))kk=0
        ind=1+ii+2*jj+4*kk
        iskip=ncoarse+(ind-1)*ngridmax
        ind_cell=iskip+igrid
        igrid=son(ind_cell)
        if(igrid==0.or.j==ilevel)exit
     end do
     cell_index(i)=ind_cell
     cell_levl(i)=j
  end do
end subroutine get_cell_index
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine read_clumpfind_params()
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  
  !--------------------------------------------------
  ! Namelist definitions                                                        
  !--------------------------------------------------

  namelist/clumpfind_params/ivar_clump,& 
       & relevance_threshold,density_threshold,&
       & saddle_threshold,mass_threshold,clinfo

  ! Read namelist file 
  rewind(1)
  read(1,NML=clumpfind_params,END=101)
  goto 102
101 write(*,*)' You need to set up namelist &CLUMPFIND_PARAMS in parameter file'
  call clean_stop
102 rewind(1)

end subroutine read_clumpfind_params
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine surface_int(ind_cell,np,ilevel)
  use amr_commons
  use clfind_commons, ONLY: center_of_mass,Psurf
  use hydro_commons, ONLY: uold,gamma
  implicit none
  integer::np,ilevel
  integer,dimension(1:nvector)::ind_grid,ind_cell

  !------------------------------------------------------------
  ! This routine constructs all neighboring leaf cells that 
  ! have a common cell surface at levels 
  ! ilevel-1, ilevel, ilevel+1. Then, it computes the pressure
  ! pressure onto these surfaces and integrates over the surface
  ! of the clumps.
  !------------------------------------------------------------

  integer::j,ind,nx_loc,i2,j2,k2,ix,iy,iz,idim,jdim,i3,j3,k3
  real(dp)::dx,dx_loc,scale,vol_loc
  integer ,dimension(1:nvector)::cell_index,cell_levl,clump_nr,indv,neigh_cl
  real(dp),dimension(1:twotondim,1:3)::xc
  real(dp),dimension(1:nvector,1:ndim)::xtest,r
  real(dp),dimension(1:nvector)::ekk_cell,ekk_neigh,P_cell,P_neigh,r_dot_n
  real(dp),dimension(1:3)::skip_loc,n
  logical ,dimension(1:nvector)::ok

#if NDIM==3

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**3

  ! Cells center position relative to grid center position
  do ind=1,twotondim
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     xc(ind,1)=(dble(ix)-0.5D0)*dx
     xc(ind,2)=(dble(iy)-0.5D0)*dx
     xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do
  
  ekk_cell=0.; P_neigh=0; P_cell=0
  ! some preliminary action...
  do j=1,np
     indv(j)=(ind_cell(j)-ncoarse-1)/ngridmax+1 ! cell position in grid
     ind_grid(j)=ind_cell(j)-ncoarse-(indv(j)-1)*ngridmax ! grid index
     clump_nr(j)=flag2(ind_cell(j)) ! save clump number
     do jdim=1,ndim
        ekk_cell(j)=ekk_cell(j)+0.5*uold(ind_cell(j),jdim+1)**2
     end do
     ekk_cell(j)=ekk_cell(j)/uold(ind_cell(j),1)
     P_cell(j)=(gamma-1.0)*(uold(ind_cell(j),ndim+2)-ekk_cell(j))
  end do


  
  !================================
  ! generate neighbors at level ilevel (and ilevel -1)
  !================================
  ! Generate 3x3 neighboring cells at level ilevel
  do k2=0,2
     do j2=0,2
        do i2=0,2
           if((k2-1.)**2+(j2-1.)**2+(i2-1.)**2==1)then !check whether common face exists 
              
              !construct outward facing normal vector
              n=0.
              if (k2==0)n(3)=-1.
              if (k2==2)n(3)=1.
              if (j2==0)n(2)=-1.
              if (j2==2)n(2)=1.
              if (i2==0)n(1)=-1.
              if (i2==2)n(1)=1.
              if (n(1)**2+n(2)**2+n(3)**2/=1)print*,'n has wrong lenght'
              
              
              r=0.
              do j=1,np                 
                 xtest(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i2-1)*dx_loc
                 xtest(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j2-1)*dx_loc
                 xtest(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k2-1)*dx_loc

                 if (clump_nr(j)>0)then                    
                    r(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i2-1)*dx_loc*0.5&
                         -center_of_mass(clump_nr(j),1)
                    r(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j2-1)*dx_loc*0.5&
                         -center_of_mass(clump_nr(j),2)
                    r(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k2-1)*dx_loc*0.5&
                         -center_of_mass(clump_nr(j),3)
                 endif                 
              end do
              
              call get_cell_index(cell_index,cell_levl,xtest,ilevel,np)
              do j=1,np           
                 ok(j)=(son(cell_index(j))==0)
              end do
              do j=1,np
                 neigh_cl(j)=flag2(cell_index(j))!nuber of clump the neighboring cell is in 
                 ok(j)=ok(j).and. neigh_cl(j)/=clump_nr(j) !neighboring cell is in another clump
                 ok(j)=ok(j).and. 0/=clump_nr(j) !clump number is not zero
              end do
              
              r_dot_n=0.
              do j=1,np
                 do idim=1,3
                    r_dot_n(j)=r_dot_n(j)+n(idim)*r(j,idim)
                 end do
              end do
              
              ekk_neigh=0.
              do j=1,np
                 if (ok(j))then 
                    do jdim=1,ndim
                       ekk_neigh(j)=ekk_neigh(j)+0.5*uold(cell_index(j),jdim+1)**2
                    end do
                    ekk_neigh(j)=ekk_neigh(j)/uold(cell_index(j),1)
                    P_neigh(j)=(gamma-1.0)*(uold(cell_index(j),ndim+2)-ekk_neigh(j))
                    Psurf(clump_nr(j))=Psurf(clump_nr(j))+r_dot_n(j)*dx_loc**2*0.5*(P_neigh(j)+P_cell(j))
                 endif
              end do
           endif
        end do
     end do
  end do
  

  !===================================
  ! generate neighbors at level ilevel+1
  !====================================  
  if(ilevel<nlevelmax)then  
     ! Generate 4x4x4 neighboring cells at level ilevel+1 
     do k3=0,3
        do j3=0,3
           do i3=0,3
              if((k3-1.5)**2+(j3-1.5)**2+(i3-1.5)**2==2.75)then !check whether common face exists

                 n=0.
                 if (k3==0)n(3)=-1. 
                 if (k3==3)n(3)=1.
                 if (j3==0)n(2)=-1. 
                 if (j3==3)n(2)=1.
                 if (i3==0)n(1)=-1. 
                 if (i3==3)n(1)=1.
                 if (n(1)**2+n(2)**2+n(3)**2/=1)print*,'n has wrong lenght'

                 r=0.
                 do j=1,np 

                    xtest(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i3-1.5)*dx_loc/2.0
                    xtest(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j3-1.5)*dx_loc/2.0
                    xtest(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k3-1.5)*dx_loc/2.0
                    
                    if (clump_nr(j)>0)then                       
                       r(j,1)=(xg(ind_grid(j),1)+xc(indv(j),1)-skip_loc(1))*scale+(i3-1.5)*dx_loc/2.0*0.5&
                            -center_of_mass(clump_nr(j),1)
                       r(j,2)=(xg(ind_grid(j),2)+xc(indv(j),2)-skip_loc(2))*scale+(j3-1.5)*dx_loc/2.0*0.5&
                            -center_of_mass(clump_nr(j),2)
                       r(j,3)=(xg(ind_grid(j),3)+xc(indv(j),3)-skip_loc(3))*scale+(k3-1.5)*dx_loc/2.0*0.5&
                            -center_of_mass(clump_nr(j),3)
                    endif
                 end do
                 call get_cell_index(cell_index,cell_levl,xtest,ilevel+1,np)

                 ok=.false.
                 do j=1,np
                    !check wether neighbor is in a leaf cell at the right level
                    if(son(cell_index(j))==0.and.cell_levl(j)==(ilevel+1))ok(j)=.true.
                 end do                 

                 do j=1,np
                    neigh_cl(j)=flag2(cell_index(j))!nuber of clump the neighboring cell is in 
                    ok(j)=ok(j).and. neigh_cl(j)/=clump_nr(j) !neighboring cell is in another clump
                    ok(j)=ok(j).and. 0/=clump_nr(j) !clump number is not zero 
                 end do
                 
                 r_dot_n=0.
                 do j=1,np
                    do idim=1,3
                       r_dot_n(j)=r_dot_n(j)+n(idim)*r(j,idim)
                    end do
                 end do

                 do j=1,np
                    if (ok(j))then
                       do jdim=1,ndim
                          ekk_neigh(j)=ekk_neigh(j)+0.5*uold(cell_index(j),jdim+1)**2
                       end do
                       ekk_neigh(j)=ekk_neigh(j)/uold(cell_index(j),1)
                       P_neigh(j)=(gamma-1.0)*(uold(cell_index(j),ndim+2)-ekk_neigh(j))
                       Psurf(clump_nr(j))=Psurf(clump_nr(j))+r_dot_n(j)*0.25*dx_loc**2*0.5*(P_neigh(j)+P_cell(j))
                       if(debug.and.((P_neigh(j)-P_cell(j))/P_cell(j))**2>4.)print*,'caution, very high p contrast',(((P_neigh(j)-P_cell(j))/P_cell(j))**2)**0.5
                    endif
                 end do                 
              endif
           end do
        end do
     end do
  endif
#endif
     
end subroutine surface_int
