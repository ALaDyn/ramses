#! /bin/bash
#######################################
# cr_write_makefile.sh [makefile name]
# creates a .f90 file with code to
# write the Makefile content to disk
#######################################


if [ $# == 0 ]
  then
  exit
fi

MAKEFILE=$1

sed "s/\"/\"\"/g;s/^/  write(ilun,format)\"/;s/$/\"/" ${MAKEFILE} > .test_middle.f90
  
cat << EOF > .test_after.f90

  close(ilun)
end subroutine output_makefile
EOF

cat << EOF > .test_before.f90
subroutine output_makefile(filename)
  character(LEN=80)::filename
  character(LEN=80)::fileloc
  character(LEN=30)::format
  integer::ilun

  ilun=11

  fileloc=TRIM(filename)
  format="(A)"
  open(unit=ilun,file=fileloc,form='formatted')
EOF

cat .test_before.f90 .test_middle.f90 .test_after.f90 > write_makefile.f90

rm .test_before.f90 .test_middle.f90 .test_after.f90

