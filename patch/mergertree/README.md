  MERGERTREE PATCH 
======================

Important notes
------------------------

 * This patch introduces two new files, because the file length got unruly. To use it, either add 
   `unbinding.o merger_tree.o` to the `PMOBJ` variable in the Makefile, or copy-paste their content into an existing 
   file, e.g. `clump_finder.f90` or `clump_merger.f90`. Otherwise, you will get a compilation error along the lines 
   of "undefined reference to subroutine unbinding"
   
 *  This patch introduces essentially two new functionalities into RAMSES. The first one is on-the-fly particle unbinding for particle clumps as found by the clump finder, the second one is on-the-fly generation of merger trees and mock galaxy catalogues. You can use particle unbinding without creating merger trees, but you can't make merger trees without particle unbinding.

 * To make merger trees or use particle unbinding, you'll first need to identify clumps on-the-fly in the simulation. To activate the clump finder, add `clumpfind=.true.` in your `&RUN_PARAMS` namelist block. More details about clumpfind parameters can be found [here][4]. For dark matter only simulations, you should probably use the following `&CLUMPFIND_PARAMS` in your parameter file:

```
    &CLUMPFIND_PARAMS
    relevance_threshold=3
    density_threshold=80
    saddle_threshold=200

```

 * Some parts of the code (e.g. binning particles in mass profiles of halos) rely on consistent floating-point  operations. 
 [The (intel) fortran compiler however doesn't necessarily use value-safe optimisations][1], which may  lead to errors. 
 (The code doesn't crash, but will warn you that something's wrong.) The error should be small  (~1e-16), and you may 
 choose to ignore it. Otherwise, you might want to compile the code with the  `-fp-model precise` flag for intel, or the 
 appropriate flag for the compiler you'd like to use.

 * For accurate merger trees, consider running your simulation for a handful (I used 3) snapshots more than you actually need to make sure past merging events are actually mergers, not just two clumps too close to each other to be recognized as distinct clumps. You'll also need to check in these "extra snapshots" later whether any clump re-emerged later.

 * I'm not really able to predict how much memory the patch will need, because it will accumulate orphan galaxies over the simulation. It shouldn't be much, but obviously will depend on how big of a simulation you are trying to run. It never was a significant amount of memory (`< 10 Mb`) when I tried it with `512^3` particles, but I'd keep that in mind if you have memory issues. 

 * The previously available `unbinding_formatted_output` namelist parameter has been removed. Make sure you remove it from your namelists if you used it!

 * For anything else regarding this patch, feel free to contact Mladen Ivkovic (mladen.ivkovic [at] hotmail DOT com)












 Particle Unbinding
-----------------------------------------------------------



### What it does

The purpose of this patch is to identify unbound particles in clumps as identified by the clumpfinder and pass 
them on to the parent clumps, until the halo-namegiver clumps are reached (where there are no more parent
structures to pass the particles on to.)

It will write unformatted output in `output_XXXXX/unbinding_XXXXX.outYYYYY` files the same way it is done for
any other backup files in `ramses`, containing the assigned clump IDs of every particle after unbinding. The
clump IDs correspond to the clump IDs as used in the `halo_XXXXX.txtYYYYY` and `clump_XXXXX.txtYYYYY` files. 
If a particle has clump ID 0, it wasn't found to be in any clump.



### How it works

The new routines are in the `unbinding.f90` file. The main routine (`unbinding`) is called in the `clump_finder` 
routine from the `clump_finder.f90` after clump properties are written to file.

First all particles that are in a clump are gathered and assigned the corresponding clump ID. 
Simultaneously, linked lists of these particles are created for each clump that is not a halo-namegiver, i.e. 
that is not a clump whose ID will be the halo ID. Such clumps are never merged into another clump, but may have
arbitrarily many clumps merged into them. Then clump properties such as centre of mass, the mass profile and bulk 
velocity are acquired using the linked lists. Starting with the lowest clump level, particles are checked if they
are bound to the clump they are assigned to. By default, this unbinding is done iteratively: The clump properties
are recomputed using only the remaining particles, and then all particles checked again. Furthermore, by default
particles are not allowed to leave the boundaries of the clump they're assigned to in order to be considered
bound; For this, the potential at the closest saddle from the clump's centre of mass to a neighbouring clump is
subtracted from the particle's energy. (This default behaviour can however be changed with the namelist 
parameters `saddle_pot` and `iter_properties`). Also note that the bulk velocity and centre of mass of a clump are
recovered using only the bound particles per iteration, the mass profile however always uses all included particles,
including the substructure particles.
The iteration per clump level stops when the bulk density of each clump of that level has converged, i.e.
`v_clump_old/v_clump_new < conv_limit` (or when a maximal number of iterations is reached). Particles that are
found to be not bound are passed to the parent structure for examination, provided such a structure exists, and the 
iterations repeated for the next clump level, provided there are clumps of a higher level.
There are two possibilities implemented to define the clump's centre. By default, the centre will be the position of the
associated density peak. However using the `-DUNBINDINGCOM` preprocessing flag, you can make the centre be the 
centre of mass, which will also be determined iteratively like the bulk velocity.

More details can be found [here][2].



### New namelist parameters for this pach

Can be set in the `CLUMPFIND_PARAMS` block




|   Name                        |   default                 |   type   |   function                                        |
|-------------------------------|---------------------------|----------|---------------------------------------------------|
| `unbind=`                     | `.true. `                 | logical  | Turn particle unbinding on or off                 |
|                               |                           |          |                                                   |
| `particlebased_clump_output=` | `.false.`                 | logical  | write resulting clump properties based on         |
|                               |                           |          | particles after unbinding, not default cell-based |
|                               |                           |          | properties                                        |
|                               |                           |          |                                                   |
| `nmassbins=`                  | `50`                      | integer  | Number of bins for the mass binning of the        |
|                               |                           |          | cumulative mass profile. Any integer > 1.         |
|                               |                           |          |                                                   |
| `logbins=`                    | `.true.`                  | logical  | use logarithmic binning distances for cumulative  |
|                               |                           |          | mass profiles (and gravitational potential of     |
|                               |                           |          | clumps). If false, the code  will use linear      |
|                               |                           |          | binning distances.                                |
|                               |                           |          |                                                   |
| `saddle_pot=`                 | `.true.`                  | logical  | Take neighbouring structures into account; Cut    |
|                               |                           |          | potential off at closest saddle.                  |
|                               |                           |          |                                                   |
| `iter_properties= `           | `.true.`                  | logical  | whether to unbind multiple times with updated     |
|                               |                           |          | clump properties determined by earlier unbindings |
|                               |                           |          |                                                   |
| `conv_limit =`                | `0.01`                    | real     | convergence limit.                                |
|                               |                           |          | If `v_clump_old/v_clump_new < conv_limit`, stop   |
|                               |                           |          | iterating for this clump. (only used when         |
|                               |                           |          | `iter_properties=.true.`)                         |
|                               |                           |          |                                                   |
| `repeat_max =`                | `100`                     | integer  | maximal number of loops per level for iterative   |
|                               |                           |          | unbinding (in case a clump doesn't converge)      |
|                               |                           |          | (shouldn't happen)                                |
|                               |                           |          | (only used when `iter_properties=.true.`)         |


















Making Merger Trees and Mock Galaxy Catalogues
-----------------------------------------------------------------------------------------

### What it does


This patch creates dark matter halo merger trees. Essentially, clumps as identified by the clumpfinder PHEW between 
two snapshots are linked as progenitors and descendants, if possible. Preferrably clumps between two adjacent 
snapshots are linked, but if a descendant has no direct progenitor in the adjacent snapshot, the program will try 
to find progenitors in older snapshots.

Optionally, it can create mock galaxy catalogues. Using a parametrised SHAM stellar-mass-halo-mass relation, the
most bound particle of each clump is assigned a stellar mass. Once a subhalo is merged, the galaxy, now an orphan,
is still being tracked until the end of the simulation.



### Mergertree Output

The merger trees are stored in `output_XXXXX/mergertree_XXXXX.txtYYYYY` files. Each file contains 11 columns:

* `clump`:            clump ID of a clump at this output number
* `progenitor`:       the progenitor clump ID in output number "prog_outputnr"
* `prog_outputnr`:    the output number of when the progenitor was an alive clump
* `desc mass`:        mass of the current clump. 
* `desc npart`:       number of particles of the current clump. 
* `desc x,y,z`:       x, y, z position of current clump.
* `desc vx, vy, vz`:  x, y, z velocities of current clump.

desc_mass and desc_npart will be either inclusive or exclusive, depending on how you set the `use_exclusive_mass` parameter. 
(See below for details)

**How to read the output:**

* A clump > 0 has progenitor > 0: Standard case. A direct progenitor from the adjacent previous snapshot was identified for this clump.
* A clump > 0 has progenitor = 0: no progenitor could be established and the clump is treated as newly formed.
* A clump > 0 has progenitor < 0: it means that no direct progenitor could be found in the adjacent previous snapshot, but a progenitor was identified from an earlier, non-adjacent snapshot.
* A clump < 0 has progenitor > 0: this progenitor merged into this clump, but is not this clump's main progenitor.
* A clump < 0 has progenitor < 0: this shouldn't happen.




### Mock Galaxy Output

The mock galaxy output is stored in `output_XXXXX/galaxies_XXXXX.txtYYYYY` files. Every file contains 5 columns:

* `Associated clump`:    Provided this is not an orphan galaxy, the clump ID in which this galaxy is. Orphan galaxies have associated clump = 0
* `Stellar Mass`:        The galaxy's stellar mass in units of solar mass.
* `x, y, z`:             position of the galaxy.
* `Galaxy Particle ID` : The ID of the particle this galaxy is attributed to.



### How it works

After every clumpfinding and unbinding step in the simulation, the merger tree code is called. For every clump, the 
`nmost_bound` number of most bound (= with lowest total energy) particles are found and written
to file, as they will be treated as tracers for this clump. In the next output step, those files will be read in 
and sorted out: The clumps of the previous output will be progenitors of this output. 
Based on in which descendant clump each progenitor's particles ended up in, progenitors and descendants are linked,
i.e. possible candidates are indentified this way. Next, the main progenitor of each descendant and the main descendant 
of each progenitor need to be found. A descendant may have multiple progenitors, but only one main progenitor. 
Progenitors however are only allowed to have one descendant, their main descendant.

The tree-making is performed iteratively. A main progenitor-descendant pair is established when the main progenitor of
a descendant is the main descendant of said progenitor. At every iteration, all descendant candidates of all progenitors
that haven't found their match yet are checked; The descendants however only move along one progenitor candidate. The 
iteration is repeated until every descendant has checked all of its candidates or found its match. Progenitors that 
haven't found a main descendant that isn't taken yet will be considered to have merged into their best fitting descendant
candidate.

After the iteration, any progenitor that is considered as merged into its descendant will be recorded as a "past merged 
progenitor". Then descendants that haven't got a progenitor will try to find a progenitor in non-adjacent snapshots, 
which are stored as "past merged progenitors". (Obviously not in one of the newly added past merged progenitors.) As the
past merged progenitors are traced via 1 particle ("galaxy particle"), the past merged progenitor of the most bound 
"galaxy particle" that is also assigned as a particle of a descendant will be considered the main progenitor of the
descendant under consideration.

Mock galaxy catalogues are created using a parametrised SHAM relation between (sub)halo mass and stellar mass adapted
from [Behroozi, Wechsler and Conroy 2013][3]. Once a subhalo merges into another clump, its (orphan) galaxy is still 
being tracked for a user-specified number of snapshots (`max_past_snapshots` paarameter below) by tracking what was the 
last identifiable most bound particle of that subhalo.

For more details on how it works, some tests and results, you can have a look [here][5]



### New namelist parameters for this pach

Can be set in the `CLUMPFIND_PARAMS` block.


|   Name                        |   default                 |   type   |   function                                        |
|-------------------------------|---------------------------|----------|---------------------------------------------------|
| `make_mergertree =`           | `.true.`                  | logical  | Turn making mergertree on or off.                 |
|                               |                           |          | `make_mergertree = .true.` sets `unbind = .true.` |
|                               |                           |          |                                                   |
| `nmost_bound = `              | `200`                     | integer  | Up to how many particles per clump to track       |
|                               |                           |          | between two snapshots.                            |
|                               |                           |          |                                                   |
| `max_past_snapshots =`        | `0`                       | integer  | maximal number of past snapshots to store. If = 0,|
|                               |                           |          | all past merged progenitors will be stored.       |
|                               |                           |          | If `make_mock_galaxies=.true.`, it will also      |
|                               |                           |          | limit the number of snapshots for which orphan    |
|                               |                           |          | galaxies are tracked.                             |
|                               |                           |          |                                                   |
| `use_exclusive_mass =`        | `.true.`                  | logical  | how to define clump mass: If false, all           |
|                               |                           |          | substructure of a clump is considered part of     |
|                               |                           |          | its mass. Otherwise, use only particles that are  |
|                               |                           |          | bound to the clump itself (excluding main haloes: |
|                               |                           |          | main haloes always consist of all the particles   |
|                               |                           |          | within them)                                      |
|                               |                           |          |                                                   |
| `make_mock_galaxies =`        | `.true.`                  | logical  | whether to also create mock galaxy catalogues     |
|                               |                           |          | on the fly.                                       |






### Visualisation

`ramses/utils/py/mergertreeplot.py` is a python 2 script to plot the merger trees as found by this patch. 
Details on options and usage are at the start of the script as a comment.





### Crashing on MPI writing routines?

Apparently some MPI implementations have issues with collective writing routines, which are used by default
in the merger tree patch. To circumvent this problem, the `-DMTREE_INDIVIDUAL_FILES` preprocessing directive
can be set in the Makefile. Just add it to the `DEFINES=` line at the top of the file.
With this flag in use, instead of collective files every MPI task will write an individual unformatted 
Fortran file, and then read it back in at the later snapshot and communicate the data appropriately.


However, be advised: Using this flag creates a lot of small files (`4* #MPI tasks` number of extra files in
addition to `2-3 * #MPI tasks` to result files for particle unbinding, merger trees, and, if chosen, galaxy
files per snapshot). This might become an issue if the machine you're working on applies file number quotas.










[1]: https://www.nccs.nasa.gov/images/FloatingPoint_consistency.pdf
[2]: https://drive.google.com/file/d/0B7IyoMUxCr-3V3NFSVFjY1lMbk0
[3]: https://arxiv.org/pdf/1207.6105.pdf 
[4]: https://bitbucket.org/rteyssie/ramses/wiki/PHEW
[5]: https://drive.google.com/open?id=1q0RSMeTIF7gQ7s2DXzYZUSG6cQ1LstkF
