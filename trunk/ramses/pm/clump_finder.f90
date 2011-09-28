subroutine clump_finder(create_output)
  use amr_commons
  use pm_commons
  use hydro_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  logical::create_output
  !----------------------------------------------------------------------------
  ! Description of clump_finder:
  ! The clumpfinder assigns a test particle to each cell having a density above 
  ! a given threshold. These particles are moved to the densest neighbors until 
  ! particles sit in a local density maximum. The particles (now containing the
  ! peak_nr they belong to) are moved back to their original position and all
  ! the relevant properties are computed. If a so called peak batch is 
  ! considered irrelevant, it is merged to the neighbor which it is connected 
  ! to through the saddle point with the highest density.
  ! Andreas Bleuler & Romain Teyssier 10/2010 - ?
  !----------------------------------------------------------------------------
  ! local constants

  integer::ipart,istep,ilevel,info,icpu,igrid,nmove,nmove_all
  character(LEN=5)::nchar
  character(LEN=80)::filename
  integer::jgrid



  !new variables for clump/sink comb
  real(dp)::scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2
  integer::j,jj,blocked
  real(dp),dimension(1:nvector,1:3)::pos
  integer,dimension(1:nvector)::cell_index,cell_levl,cc


  if(verbose)write(*,*)' Entering clump_finder'

  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  call remove_parts_brute_force
  
  !-------------------------------------------------------------------------------
  ! Create test particle
  !-------------------------------------------------------------------------------
  nstar_tot=0
  do ilevel=levelmin,nlevelmax
     call create_test_particle(ilevel)
  end do
  do ilevel=nlevelmax,levelmin,-1
     call merge_tree_fine(ilevel)
  end do

  !-------------------------------------------------------------------------------
  ! Move particle along steepest ascent to  peak
  !-------------------------------------------------------------------------------
  nmove=nstar_tot
  istep=0
  do while(nmove>0)
     if(myid==1 .and. verbose)write(*,*)"istep=",istep,"nmove=",nmove


     ! Move particle across oct and processor boundaries
     do ilevel=levelmin,nlevelmax
        call make_tree_fine(ilevel)
        call kill_tree_fine(ilevel)
        call virtual_tree_fine(ilevel)
     end do

     ! Proceed one step to densest neighbor
     nmove=0; nmove_all=0
     istep=istep+1
     do ilevel=nlevelmax,levelmin,-1
        call move_test(nmove,ilevel)
        call merge_tree_fine(ilevel)
     end do
#ifndef WITHOUTMPI     
     call MPI_ALLREDUCE(nmove,nmove_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
     nmove=nmove_all
#endif
     !uncomment these lines if you want to follow the move of the test particles 
     !call title(istep,nchar)
     !filename='clump/part_'//TRIM(nchar)//'.out'
     !call backup_part(filename)

  end do



  call assign_part_to_peak()


  !-------------------------------------------------------------------------------
  ! Re-assign xp to the old position stored in vp (argument is the level in which
  ! the particles sit)
  !-------------------------------------------------------------------------------
  do ilevel=levelmin-1,1,-1
     call merge_tree_fine(ilevel)
  end do
  call move_back_to_origin(1)
  do ilevel=1,nlevelmax
     call virtual_tree_fine(ilevel)
     call kill_tree_fine(ilevel)
  end do


  call allocate_peak_batch_arrays()


  !-------------------------------------------------------------------------------
  ! Compute peak-batch mass etc. and output these properties before merging 
  !-------------------------------------------------------------------------------
  call compute_clump_properties() 
  if (sink .eqv. .false. .or. mod(nstep_coarse,ncontrol)==0)call write_clump_properties(.false.)


  !-------------------------------------------------------------------------------
  ! find the saddlepoint densities and merge irrelevant clumps
  !-------------------------------------------------------------------------------
  if (npeaks_tot > 0)then
     call saddlepoint_search() 
     call merge_clumps() 
  end if

  !-------------------------------------------------------------------------------
  ! output to file  clump_properties and a complete map of all the cell-centers 
  ! together with the peak the cell belongs to
  !-------------------------------------------------------------------------------
  if (npeaks_tot > 0)then
     call clump_phi
     call compute_clump_properties_round2()
     if (sink .eqv. .false. .or. mod(nstep_coarse,ncontrol)==0)call write_clump_properties(.false.)
     if(create_output)then
        call write_peak_map
        call write_clump_properties(.true.)
     end if
  end if

  


  !------------------------------------------------------------------------------
  ! if the clumpfinder is used to produce sinks, flag all the cells which contain
  ! a relevant density peak whose peak patch doesn't yet contain a sink.
  !------------------------------------------------------------------------------
  if(sink)then

     allocate(occupied(1:npeaks_tot),occupied_all(1:npeaks_tot))
     occupied=0; occupied_all=0;

     !loop over sinks and mark all clumps containing a sink
     pos=0.0
     blocked=0
     if(myid==1 .and. verbose)write(*,*)'looping over ',nsink,' sinks and marking their clumps'
     do j=1,nsink
        pos(1,1:3)=xsink(j,1:3)
        call cmp_cpumap(pos,cc,1)
        if (cc(1) .eq. myid)then
           call get_cell_index(cell_index,cell_levl,pos,nlevelmax,1)
           if (flag2(cell_index(1))>0)then 
              occupied(flag2(cell_index(1)))=1
              blocked=blocked+1
              if(verbose)write(*,*)'CPU # ',myid,'blocked clump # ',flag2(cell_index(1)),' for sink production because of sink # ',j
           end if
        end if
     end do

     
#ifndef WITHOUTMPI
     call MPI_ALLREDUCE(occupied,occupied_all,npeaks_tot,MPI_INTEGER,MPI_MAX,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
     occupied_all=occupied
#endif

     pos=0.0
     flag2=0.
     call heapsort_index(max_dens_tot,sort_index,npeaks_tot)
     do j=npeaks_tot,1,-1
        jj=sort_index(j)
        if (relevance_tot(jj) > 1.0d-1 .and. occupied_all(jj)==0 .and. minmatch_tot(jj)==1)then           
           if (e_bind_tot(jj)/(e_thermal_tot(jj)+e_kin_int_tot(jj)) > 1.)then
              if (clump_mass_tot(jj)-clump_vol_tot(jj)*n_sink/scale_nH  > mass_threshold)then
                 pos(1,1:3)=peak_pos_tot(jj,1:3)
                 call cmp_cpumap(pos,cc,1)
                 if (cc(1) .eq. myid)then
                    call get_cell_index(cell_index,cell_levl,pos,nlevelmax,1)
                    flag2(cell_index(1))=1.
                 end if
              end if
           end if
        end if
     end do
     deallocate(occupied,occupied_all)
  endif





  call remove_parts_brute_force
  call deallocate_all

end subroutine clump_finder


!################################################################
!################################################################
!################################################################
!################################################################
subroutine remove_parts_brute_force
  use amr_commons
  use pm_commons
  use hydro_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------
  ! removes all particles using brute force - soft attempt did not work...
  !----------------------------------------------------------------------

  integer::ipart,ilevel,icpu,igrid,jgrid,info


  npart=0
  do icpu=1,ncpu
     do ilevel=1,nlevelmax
        igrid=headl(icpu,ilevel) 
        do jgrid=1,numbl(icpu,ilevel) 
           headp(igrid)=0
           tailp(igrid)=0
           numbp(igrid)=0
           igrid=next(igrid)   ! Go to next grid
        end do
     end do
  end do
  

  !----------------------------------
  ! Reinitialize free memory linked list
  !----------------------------------
  prevp(1)=0; nextp(1)=2
  do ipart=2,npartmax-1
     prevp(ipart)=ipart-1
     nextp(ipart)=ipart+1
  end do
  prevp(npartmax)=npartmax-1; nextp(npartmax)=0
  ! Free memory linked list
  headp_free=1
  tailp_free=npartmax
  numbp_free=tailp_free-headp_free+1
  if(numbp_free>0)then
     prevp(headp_free)=0
  end if
  nextp(tailp_free)=0
  numbp_free_tot=numbp_free

  !----------------------------------
  ! Reinitialize particle variables
  !----------------------------------
  xp=0.0
  vp=0.0
  mp=0.0
  idp=0
  levelp=0
  if(star.or.sink)then
     tp=0.0
     if(metal)zp=0.0
  endif


end subroutine remove_parts_brute_force

!################################################################
!################################################################
!################################################################
!################################################################
subroutine create_test_particle(ilevel)
  use amr_commons
  use pm_commons
  use hydro_commons
  use cooling_module, ONLY: XH=>X, rhoc, mH 
  use random
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  integer::ilevel
  !----------------------------------------------------------------------
  ! Description: This routine creates a particle in each cell which lies 
  ! above the density threshold.
  ! Yann Rasera  10/2002-01/2003
  !----------------------------------------------------------------------
  ! local constants
  real(dp)::d0
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  real(dp),dimension(1:twotondim,1:3)::xc
  ! other variables
  integer ::ncache,nnew,ngrid,icpu,index_star
  integer ::igrid,ix,iy,iz,ind,i,iskip,nx_loc
  integer ::ntot,ntot_all,info
  logical ::ok_free
  real(dp),dimension(1:3)::skip_loc
  real(dp)::d,x,y,z,dx,dx_loc,scale,vol_loc,dx_min,vol_min
  integer ,dimension(1:nvector),save::ind_grid,ind_cell
  integer ,dimension(1:nvector),save::ind_grid_new,ind_cell_new,ind_part
  logical ,dimension(1:nvector),save::ok,ok_new=.true.
  integer ,dimension(1:ncpu)::ntot_star_cpu,ntot_star_all

  if(numbtot(1,ilevel)==0) return
  if(.not. hydro)return
  if(ndim.ne.3)return

  if(verbose)write(*,*)' Entering test particle creation'

  ! Conversion factor from user units to cgs units
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)

  ! Mesh spacing in that level
  dx=0.5D0**ilevel 
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**ndim
  dx_min=(0.5D0**nlevelmax)*scale
  vol_min=dx_min**ndim

  ! Clump density threshold from H/cc to code units
  d0   = density_threshold/scale_nH

  ! Cells center position relative to grid center position
  do ind=1,twotondim  
     iz=(ind-1)/4
     iy=(ind-1-4*iz)/2
     ix=(ind-1-2*iy-4*iz)
     xc(ind,1)=(dble(ix)-0.5D0)*dx
     xc(ind,2)=(dble(iy)-0.5D0)*dx
     xc(ind,3)=(dble(iz)-0.5D0)*dx
  end do

#if NDIM==3
  !------------------------------------------------
  ! Compute number of new test particles in the level ilevel
  !------------------------------------------------
  ntot=0 
  ! Loop over grids
  ncache=active(ilevel)%ngrid
  do igrid=1,ncache,nvector
     ngrid=MIN(nvector,ncache-igrid+1)
     do i=1,ngrid
        ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
     end do
     ! Test particle formation ---> logical array ok(i)
     do ind=1,twotondim
        iskip=ncoarse+(ind-1)*ngridmax
        do i=1,ngrid
           ind_cell(i)=iskip+ind_grid(i)
        end do
        ! Flag leaf cells
        do i=1,ngrid
           ok(i)=son(ind_cell(i))==0
        end do
        ! Density criterion
        do i=1,ngrid
           d=uold(ind_cell(i),1)
           if(d<=d0)ok(i)=.false. 
        end do
        ! Compute test particle map
        do i=1,ngrid
           flag2(ind_cell(i))=0
           if(ok(i))then
              flag2(ind_cell(i))=1
              ntot=ntot+1
           endif
        end do
     end do
  end do

  !---------------------------------
  ! Check for free particle memory
  !---------------------------------
  ok_free=(numbp_free-ntot)>=0
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(numbp_free,numbp_free_tot,1,MPI_INTEGER,MPI_MIN,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  numbp_free_tot=numbp_free
#endif
  if(.not. ok_free)then
     write(*,*)'No more free memory for particles'
     write(*,*)'Increase npartmax'
#ifndef WITHOUTMPI
     call MPI_ABORT(MPI_COMM_WORLD,1,info)
#else
     stop
#endif
  end if

  !---------------------------------
  ! Compute test particle statistics
  !---------------------------------
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ntot,ntot_all,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  ntot_all=ntot
#endif
  ntot_star_cpu=0; ntot_star_all=0
  ntot_star_cpu(myid)=ntot
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(ntot_star_cpu,ntot_star_all,ncpu,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
  ntot_star_cpu(1)=ntot_star_all(1)
#endif
  do icpu=2,ncpu
     ntot_star_cpu(icpu)=ntot_star_cpu(icpu-1)+ntot_star_all(icpu)
  end do
  nstar_tot=nstar_tot+ntot_all
  if(myid==1)then
     if(ntot_all.gt.0.and.verbose)then
        write(*,'(" Level=",I6," New test particle=",I6," Tot=",I10)')&
             & ilevel,ntot_all,nstar_tot
     endif
  end if

  !------------------------------
  ! Create new test particles
  !------------------------------
  ! Starting identity number
  if(myid==1)then
     index_star=nstar_tot-ntot_all
  else
     index_star=nstar_tot-ntot_all+ntot_star_cpu(myid-1)
  end if

  ! Loop over grids
  ncache=active(ilevel)%ngrid
  do igrid=1,ncache,nvector
     ngrid=MIN(nvector,ncache-igrid+1)
     do i=1,ngrid
        ind_grid(i)=active(ilevel)%igrid(igrid+i-1)
     end do

     ! Loop over cells
     do ind=1,twotondim
        iskip=ncoarse+(ind-1)*ngridmax
        do i=1,ngrid
           ind_cell(i)=iskip+ind_grid(i)
        end do

        ! Flag cells with test particle
        do i=1,ngrid
           ok(i)=flag2(ind_cell(i))>0
        end do

        ! Gather new test particle arrays
        nnew=0
        do i=1,ngrid
           if (ok(i))then
              nnew=nnew+1
              ind_grid_new(nnew)=ind_grid(i)
              ind_cell_new(nnew)=ind_cell(i)
           end if
        end do

        ! Update linked list for test particles
        call remove_free(ind_part,nnew)
        call add_list(ind_part,ind_grid_new,ok_new,nnew)

        ! Calculate new test particle positions
        do i=1,nnew
           index_star=index_star+1

           ! Get cell center positions
           x=(xg(ind_grid_new(i),1)+xc(ind,1)-skip_loc(1))*scale
           y=(xg(ind_grid_new(i),2)+xc(ind,2)-skip_loc(2))*scale
           z=(xg(ind_grid_new(i),3)+xc(ind,3)-skip_loc(3))*scale

           ! Set test particle variables
           levelp(ind_part(i))=ilevel   ! Level
           idp(ind_part(i))=index_star  ! Star identity
           xp(ind_part(i),1)=x
           xp(ind_part(i),2)=y
           xp(ind_part(i),3)=z
           vp(ind_part(i),1)=x
           vp(ind_part(i),2)=y
           vp(ind_part(i),3)=z
        end do
        ! End loop over new test particles
     end do
     ! End loop over cells
  end do
  ! End loop over grids
#endif

end subroutine create_test_particle
!################################################################
!################################################################
!################################################################
!################################################################
subroutine move_test(nmove,ilevel)
  use amr_commons
  use pm_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h' 
#endif
  integer::nmove,ilevel
  !----------------------------------------------------------------------
  ! Move all particles on ilevel to the densest neighbor
  !----------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,npart1
  integer,dimension(1:nvector),save::ind_grid,ind_part,ind_grid_part

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Update particles position and velocity
  ig=0
  ip=0
  ! Loop over grids
  igrid=headl(myid,ilevel)
  do jgrid=1,numbl(myid,ilevel)
     npart1=numbp(igrid)  ! Number of particles in the grid
     if(npart1>0)then        
        ig=ig+1
        ind_grid(ig)=igrid
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle  <---- Very important !!!
           next_part=nextp(ipart)
           if(ig==0)then
              ig=1
              ind_grid(ig)=igrid
           end if
           ip=ip+1
           ind_part(ip)=ipart
           ind_grid_part(ip)=ig   
           if(ip==nvector)then
              call movet(ind_grid,ind_part,ind_grid_part,ig,ip,nmove,ilevel)
              ip=0
              ig=0
           end if
           ipart=next_part  ! Go to next particle
        end do
        ! End loop over particles
     end if
     igrid=next(igrid)   ! Go to next grid
  end do
  ! End loop over grids
  if(ip>0)call movet(ind_grid,ind_part,ind_grid_part,ig,ip,nmove,ilevel)

111 format('   Entering move_test for level ',I2)

end subroutine move_test
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine movet(ind_grid,ind_part,ind_grid_part,ng,np,nm,ilevel)
  use amr_commons
  use pm_commons
  use poisson_commons
  use hydro_commons, ONLY: uold
  implicit none
  integer::ng,np,nm,ilevel
  integer,dimension(1:nvector)::ind_grid
  integer,dimension(1:nvector)::ind_grid_part,ind_part
  !------------------------------------------------------------
  ! This routine moves the particles in the arrays of length 
  ! nvector one step to the densest neighbor. It returns the
  ! number of particles which have effectively moved.
  !------------------------------------------------------------
  logical::error
  integer::i,j,ind,idim,nx_loc,i1,j1,k1,i2,j2,k2
  real(dp)::dx,dx_loc,scale,vol_loc
  integer::i1min,i1max,j1min,j1max,k1min,k1max
  integer::i2min,i2max,j2min,j2max,k2min,k2max
  integer::i3min,i3max,j3min,j3max,k3min,k3max
  ! Grid-based arrays
  real(dp),dimension(1:nvector,1:ndim),save::x0
  ! Particle-based arrays
  real(dp),dimension(1:nvector,1:ndim),save::x,xtest,xmax
  real(dp),dimension(1:nvector),save::density_max,rr
  integer ,dimension(1:nvector,1:ndim),save::ig,id
  integer ,dimension(1:nvector),save::cell_index,cell_levl,ind_max
  real(dp),dimension(1:nvector,1:ndim,1:twotondim),save::xpart
  real(dp),dimension(1:3)::skip_loc

  ! Meshspacing in that level
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
  i1min=0; i1max=0; i2min=0; i2max=0; i3min=1; i3max=1
  j1min=0; j1max=0; j2min=0; j2max=0; j3min=1; j3max=1
  k1min=0; k1max=0; k2min=0; k2max=0; k3min=1; k3max=1
  if(ndim>0)then
     i1max=2; i2max=3; i3max=2
  end if
  if(ndim>1)then
     j1max=2; j2max=3; j3max=2
  end if
  if(ndim>2)then
     k1max=2; k2max=3; k3max=2
  end if

  !====================================================
  ! Get particle density and cell
  !====================================================
  do j=1,np
     xtest(j,1:ndim)=xp(ind_part(j),1:ndim)
  end do
  call get_cell_index(cell_index,cell_levl,xtest,ilevel,np)
  do j=1,np
     density_max(j)=uold(cell_index(j),1)*1.0001
     ind_max(j)=cell_index(j)
     xmax(j,1:ndim)=xp(ind_part(j),1:ndim)
  end do

  !====================================================
  ! Check for potential new positions at level ilevel-1
  !====================================================
  if(ilevel>levelmin)then

     ! Lower left corner of 3x3x3 grid-cube
     do idim=1,ndim
        do i=1,ng
           x0(i,idim)=xg(ind_grid(i),idim)-3.0D0*dx
        end do
     end do

     ! Rescale particle position at level ilevel-1
     do idim=1,ndim
        do j=1,np
           x(j,idim)=xp(ind_part(j),idim)/scale+skip_loc(idim)
        end do
     end do
     do idim=1,ndim
        do j=1,np
           x(j,idim)=x(j,idim)-x0(ind_grid_part(j),idim)
        end do
     end do
     do idim=1,ndim
        do j=1,np
           x(j,idim)=x(j,idim)/dx
        end do
     end do
     do idim=1,ndim
        do j=1,np
           x(j,idim)=x(j,idim)/2.0D0
        end do
     end do

     ! Check for illegal moves
     error=.false.
     do idim=1,ndim
        do j=1,np
           if(x(j,idim)<0.5D0.or.x(j,idim)>2.5D0)error=.true.
        end do
     end do
     if(error)then
        write(*,*)'problem in move'
        do idim=1,ndim
           do j=1,np
              if(x(j,idim)<0.5D0.or.x(j,idim)>2.5D0)then
                 write(*,*)x(j,1:ndim)
              endif
           end do
        end do
        stop
     end if

     !  ! Do CIC at level ilevel-1
     !   do idim=1,ndim
     !      do j=1,np
     !         dd(j,idim)=x(j,idim)+0.5D0
     !         id(j,idim)=dd(j,idim)
     !         dd(j,idim)=dd(j,idim)-id(j,idim)
     !         dg(j,idim)=1.0D0-dd(j,idim)
     !         ig(j,idim)=id(j,idim)-1
     !      end do
     !   end do

     ! Compute parent cell position
#if NDIM==1
     do j=1,np
        xpart(j,1,1)=0.5+ig(j,1)
        xpart(j,1,2)=0.5+id(j,1)
     end do
#endif
#if NDIM==2
     do j=1,np
        ! Particle 1
        xpart(j,1,1)=0.5+ig(j,1)
        xpart(j,2,1)=0.5+ig(j,2)
        ! Particle 2
        xpart(j,1,2)=0.5+id(j,1)
        xpart(j,2,2)=0.5+ig(j,2)
        ! Particle 3
        xpart(j,1,3)=0.5+ig(j,1)
        xpart(j,2,3)=0.5+id(j,2)
        ! Particle 4
        xpart(j,1,4)=0.5+id(j,1)
        xpart(j,2,4)=0.5+id(j,2)
     end do
#endif
#if NDIM==3
     do j=1,np
        ! Particle 1
        xpart(j,1,1)=0.5+ig(j,1)
        xpart(j,2,1)=0.5+ig(j,2)
        xpart(j,3,1)=0.5+ig(j,3)
        ! Particle 2
        xpart(j,1,2)=0.5+id(j,1)
        xpart(j,2,2)=0.5+ig(j,2)
        xpart(j,3,2)=0.5+ig(j,3)
        ! Particle 3
        xpart(j,1,3)=0.5+ig(j,1)
        xpart(j,2,3)=0.5+id(j,2)
        xpart(j,3,3)=0.5+ig(j,3)
        ! Particle 4
        xpart(j,1,4)=0.5+id(j,1)
        xpart(j,2,4)=0.5+id(j,2)
        xpart(j,3,4)=0.5+ig(j,3)
        ! Particle 5
        xpart(j,1,5)=0.5+ig(j,1)
        xpart(j,2,5)=0.5+ig(j,2)
        xpart(j,3,5)=0.5+id(j,3)
        ! Particle 6
        xpart(j,1,6)=0.5+id(j,1)
        xpart(j,2,6)=0.5+ig(j,2)
        xpart(j,3,6)=0.5+id(j,3)
        ! Particle 7
        xpart(j,1,7)=0.5+ig(j,1)
        xpart(j,2,7)=0.5+id(j,2)
        xpart(j,3,7)=0.5+id(j,3)
        ! Particle 8
        xpart(j,1,8)=0.5+id(j,1)
        xpart(j,2,8)=0.5+id(j,2)
        xpart(j,3,8)=0.5+id(j,3)
     end do
#endif

     ! Test those particles
     do ind=1,twotondim
        do idim=1,ndim
           do j=1,np
              xtest(j,idim)=xpart(j,idim,ind)*2.*dx+x0(ind_grid_part(j),idim)
           end do
           do j=1,np
              xtest(j,idim)=(xtest(j,idim)-skip_loc(idim))*scale
           end do
        end do
        call get_cell_index(cell_index,cell_levl,xtest,ilevel-1,np)
        do j=1,np
           if(son(cell_index(j))==0)then
              if(uold(cell_index(j),1)>density_max(j))then
                 density_max(j)=uold(cell_index(j),1)
                 ind_max(j)=cell_index(j)
                 xmax(j,1:ndim)=xtest(j,1:ndim)
              endif
           endif
        end do
     end do

  endif

  !====================================================
  ! Check for potential new positions at level ilevel
  !====================================================
  ! Generate 3x3x3 neighboring cells at level ilevel
  do k1=k1min,k1max
     do j1=j1min,j1max
        do i1=i1min,i1max

           do j=1,np
              xtest(j,1)=xp(ind_part(j),1)+(i1-1)*dx_loc
#if NDIM>1
              xtest(j,2)=xp(ind_part(j),2)+(j1-1)*dx_loc
#endif     
#if NDIM>2
              xtest(j,3)=xp(ind_part(j),3)+(k1-1)*dx_loc
#endif     
           end do

           call get_cell_index(cell_index,cell_levl,xtest,ilevel,np)

           do j=1,np
              if(son(cell_index(j))==0.and.cell_levl(j)==ilevel)then
                 if(uold(cell_index(j),1)>density_max(j))then
                    density_max(j)=uold(cell_index(j),1)
                    ind_max(j)=cell_index(j)
                    xmax(j,1:ndim)=xtest(j,1:ndim)
                 endif
              endif
           end do

        end do
     end do
  end do

  !====================================================
  ! Check for potential new positions at level ilevel+1
  !====================================================
  if(ilevel<nlevelmax)then

     ! Generate 4x4x4 neighboring cells at level ilevel+1
     do k2=k2min,k2max
        do j2=j2min,j2max
           do i2=i2min,i2max

              do j=1,np
                 xtest(j,1)=xp(ind_part(j),1)+(i2-1.5)*dx_loc/2.0
#if NDIM>1
                 xtest(j,2)=xp(ind_part(j),2)+(j2-1.5)*dx_loc/2.0
#endif     
#if NDIM>2
                 xtest(j,3)=xp(ind_part(j),3)+(k2-1.5)*dx_loc/2.0
#endif     
              end do
              call get_cell_index(cell_index,cell_levl,xtest,ilevel+1,np)
              do j=1,np
                 if(son(cell_index(j))==0.and.cell_levl(j)==(ilevel+1))then
                    if(uold(cell_index(j),1)>density_max(j))then
                       density_max(j)=uold(cell_index(j),1)
                       ind_max(j)=cell_index(j)
                       xmax(j,1:ndim)=xtest(j,1:ndim)
                    endif
                 endif
              end do
           end do
        end do
     end do

  endif

  !====================================================
  ! Update position
  !====================================================
  rr(1:np)=0.0
  do idim=1,ndim
     do j=1,np
        rr(j)=rr(j)+(xp(ind_part(j),idim)-xmax(j,idim))**2
     end do
  end do
  do j=1,np
     xp(ind_part(j),1:ndim)=xmax(j,1:ndim)
     idp(ind_part(j))=ind_max(j)
  end do
  do j=1,np
     if(rr(j)>1d-3*dx_loc**2)then
        nm=nm+1
     endif
  end do

end subroutine movet

!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine assign_part_to_peak()
  use amr_commons
  use hydro_commons
  use pm_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------------
  ! This subroutine loops over all particles and marks every cell containing a
  ! particle (flag 2). Every cell containig a particle is a peak.
  ! The number of peaks on each cpu is counted. Using MPI communication, a GLOBAL
  ! peak index is given to each peak. 
  ! In a second loop over all particles, the peak index a particle belongs to,
  ! is written into the mass variable of each particle.
  !----------------------------------------------------------------------------

  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,ilevel,npart1,info
  integer::jj,peak_nr,icpu
  integer::n_cls

  integer,dimension(1:nvector)::ind_grid,ind_cell,init_ind_cell,init_cell_lev,cell_lev
  integer,dimension(1:nvector)::ind_part,ind_grid_part
  real(dp),dimension(1:nvector,1:ndim)::pos,init_pos
  real(dp),allocatable,dimension(:,:)::peak_pos
  integer,dimension(1:ncpu)::npeaks_per_cpu,npeaks_per_cpu_tot



  
  !----------------------------------------------------------------------------
  ! loop over all particles (on levelmin) and write -1 into the flag2 of each 
  ! cell which contains a particle
  !----------------------------------------------------------------------------
  nparts=0
  flag2=0   !use flag2 as temporary array 
  ilevel=levelmin
  ig=0
  ip=0
  ! Loop over grids 
  do icpu=1,ncpu !loop cpus
     igrid=headl(icpu,ilevel) 
     do jgrid=1,numbl(icpu,ilevel) ! Number of grids in the level ilevel on process myid
        npart1=numbp(igrid)  ! Number of particles in the grid
        nparts=npart1+nparts
        if(npart1>0)then
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle  <---- Very important !!!
              next_part=nextp(ipart)
              if(ig==0)then
                 ig=1
                 ind_grid(ig)=igrid
              end if
              ip=ip+1
              ind_part(ip)=ipart
              ind_grid_part(ip)=ig   
              if(ip==nvector)then 
                 call get_cell_indices(init_ind_cell,init_cell_lev,ind_cell,cell_lev,ind_part,init_pos,pos,ip,nlevelmax)
                 do jj=1,nvector
                    flag2(ind_cell(jj))=-1
                 end do
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do
     if(ip>0)then 
        call get_cell_indices(init_ind_cell,init_cell_lev,ind_cell,cell_lev,ind_part,init_pos,pos,ip,nlevelmax)
        do jj=1,ip
           flag2(ind_cell(jj))=-1
        end do
     end if
  end do
  !end loop over all particles

#ifndef WITHOUTMPI     
  call MPI_ALLREDUCE(nparts,nparts_tot,1,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  nparts_tot=nparts
#endif


  if(verbose)write(*,*)'parts on myid ',myid,' = ',nparts,nparts_tot

  !----------------------------------------------------------------------------
  ! loop over all cells and count number of peaks per processor
  !----------------------------------------------------------------------------
  npeaks=0  
  n_cls=size(flag2,1)
  do jj=0,n_cls-1
     npeaks=npeaks-flag2(jj)
  end do
  if (verbose)write(*,*)'n_peaks on processor number',myid,'= ',npeaks
  npeaks_per_cpu=0
  npeaks_per_cpu(myid)=npeaks

  !----------------------------------------------------------------------------
  ! share number op peaks per cpu and create a list
  !----------------------------------------------------------------------------
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
  if (verbose .and. myid==1)write(*,*)'total number of density peaks found = ',npeaks_tot


  !----------------------------------------------------------------------------
  ! determine peak-ids positions for each cpu
  !----------------------------------------------------------------------------
  peak_nr=1
  do icpu=1,myid-1
     peak_nr=peak_nr+npeaks_per_cpu_tot(icpu)
  end do


  !----------------------------------------------------------------------------
  ! write the peak_number into each cell above the threshold
  !----------------------------------------------------------------------------
  do jj=0,n_cls-1
     if(flag2(jj)==-1)then
        flag2(jj)=peak_nr
        peak_nr=peak_nr+1
     end if
  end do

  !----------------------------------------------------------------------------
  ! allocate arrays where the postiton of the peaks is stored
  !----------------------------------------------------------------------------
  allocate(peak_pos(1:npeaks_tot,1:ndim)); 
  allocate(peak_pos_tot(1:npeaks_tot,1:ndim))
  peak_pos=0.

  !----------------------------------------------------------------------------
  ! loop over all particles (on levelmin) and write the peak_nr into the mass 
  ! variable of each particle. save position of the peaks
  !----------------------------------------------------------------------------
  ilevel=levelmin
  ig=0
  ip=0
  do icpu=1,ncpu !loop cpus
     ! Loop over grids
     igrid=headl(icpu,ilevel) 
     do jgrid=1,numbl(icpu,ilevel) ! Number of grids in the level ilevel on process myid
        npart1=numbp(igrid)  ! Number of particles in the grid
        if(npart1>0)then
           ig=ig+1
           ind_grid(ig)=igrid
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle  <---- Very important !!!
              next_part=nextp(ipart)
              if(ig==0)then
                 ig=1
                 ind_grid(ig)=igrid
              end if
              ip=ip+1
              ind_part(ip)=ipart
              ind_grid_part(ip)=ig   
              if(ip==nvector)then 
                 call get_cell_indices(init_ind_cell,init_cell_lev,ind_cell,cell_lev,ind_part,init_pos,pos,ip,nlevelmax)
                 do jj=1,nvector
                    mp(ind_part(jj))=1.*flag2(ind_cell(jj))
                    peak_pos(flag2(ind_cell(jj)),1:ndim)=pos(jj,1:ndim)
                 end do
                 ip=0
                 ig=0
              end if
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do
     if(ip>0)then 
        call get_cell_indices(init_ind_cell,init_cell_lev,ind_cell,cell_lev,ind_part,init_pos,pos,ip,nlevelmax)
        do jj=1,ip
           mp(ind_part(jj))=1.*flag2(ind_cell(jj))  
           peak_pos(flag2(ind_cell(jj)),1:ndim)=pos(jj,1:ndim)
        end do
     end if
  end do
  !end loop over all particles


  !----------------------------------------------------------------------------
  ! create global list of peak positions
  !----------------------------------------------------------------------------
#ifndef WITHOUTMPI
  call MPI_ALLREDUCE(peak_pos,peak_pos_tot,3*npeaks_tot,MPI_DOUBLE_PRECISION,MPI_MAX,MPI_COMM_WORLD,info)
#endif
#ifdef WITHOUTMPI
  peak_pos_tot=peak_pos
#endif

  deallocate(peak_pos) !from here on only peak_pos_tot is used

end subroutine assign_part_to_peak

!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine get_cell_indices(init_cell_index,init_cell_lev,cell_index,cell_lev,ind_part,init_pos,xtest,np,ilevel)
  use amr_commons
  use hydro_commons
  use pm_commons
  implicit none

  real(dp),dimension(1:nvector,1:ndim)::init_pos,xtest
  integer::ilevel,np
  integer,dimension(1:nvector)::ind_part,init_cell_index,cell_index,cell_lev,init_cell_lev

  !----------------------------------------------------------------------------
  ! routine gets the index of the initial cell and the index of the final cell
  ! (peak cell) 
  !----------------------------------------------------------------------------
  
  integer::j
  
  do j=1,np
     init_pos(j,1)=vp(ind_part(j),1)
     xtest(j,1)=xp(ind_part(j),1)
#if NDIM>1
     init_pos(j,2)=vp(ind_part(j),2)
     xtest(j,2)=xp(ind_part(j),2)
#endif     
#if NDIM>2
     init_pos(j,3)=vp(ind_part(j),3)  
     xtest(j,3)=xp(ind_part(j),3)
#endif     
  end do

  call get_cell_index(cell_index,cell_lev,xtest,ilevel,np)
  call get_cell_index(init_cell_index,init_cell_lev,init_pos,ilevel,np)


end subroutine get_cell_indices

!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine get_cell_index(cell_index,cell_levl,xpart,ilevel,np)
  use amr_commons
  implicit none

  integer::np,ilevel
  integer,dimension(1:nvector)::cell_index,cell_levl
  real(dp),dimension(1:nvector,1:3)::xpart

  !----------------------------------------------------------------------------
  ! This routine returns the index of the cell, at maximum level
  ! ilevel, in which the input particle sits
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
  do i=1,np
     xx = xpart(i,1) + (nx-1)/2.0
     yy = xpart(i,2) + (ny-1)/2.0
     zz = xpart(i,3) + (nz-1)/2.0
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
subroutine move_back_to_origin(ilevel)
  use amr_commons
  use hydro_commons
  use pm_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !----------------------------------------------------------------------------
  ! Loop over all particles in order to move them back to there original 
  ! position which is stored in the velocity variables of the particles.
  !----------------------------------------------------------------------------

  integer::igrid,jgrid,ipart,jpart,next_part,ilevel,npart1,icpu,nparts

  nparts=0
  !loop over all particles
  do icpu=1,ncpu
     ! Loop over grids
     igrid=headl(icpu,ilevel) 
     do jgrid=1,numbl(icpu,ilevel) ! Number of grids 
        npart1=numbp(igrid)  ! Number of particles in the grid
        nparts=nparts+npart1
        if(npart1>0)then
           ipart=headp(igrid)
           ! Loop over particles
           do jpart=1,npart1
              ! Save next particle  <---- Very important !!!
              next_part=nextp(ipart)
              xp(ipart,1:ndim)=vp(ipart,1:ndim)!
              ipart=next_part  ! Go to next particle
           end do
           ! End loop over particles
        end if
        igrid=next(igrid)   ! Go to next grid
     end do
  end do
  !end loop over all particles

  if (verbose)write(*,*),'number of particles moved on ',myid,' = ',nparts
end subroutine move_back_to_origin

subroutine read_clumpfind_params()
  use clfind_commons
  use amr_commons
  use hydro_commons

  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif

  !--------------------------------------------------                           
  ! Namelist definitions                                                        
  !--------------------------------------------------                           
  real(dp)::dummy,scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2
  namelist/clumpfind_params/relevance_threshold,density_threshold,mass_threshold

  ! Read namelist file 
  rewind(1)
  read(1,NML=clumpfind_params,END=101)
  goto 102
101 write(*,*)' You need to set up namelist &CLUMPFIND_PARAMS in parameter file'
  call clean_stop
102 rewind(1)
  
  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  
  !convert mass_threshold from solar masses to grams
  dummy=mass_threshold*1.98892d33 
  !...and to user units
  mass_threshold=dummy/(scale_l**3. * scale_d)
end subroutine read_clumpfind_params
