"""Plot results of sink accretion test"""
import matplotlib
matplotlib.use('Agg')

from matplotlib import pyplot as plt
from matplotlib import ticker
import visu_ramses
import numpy as np
from scipy.interpolate import griddata

out_end = 17

# Fundamental constants
G = 6.67259e-8 #cm^3 g^-1 s^-2             # gravitational constant
YR = 3.1556926e7 #s                        # 1 year
MSUN = 1.989e33 #g                         # solar mass
MH = 1.6737236e-24 #g                      # hydrogen mass
KB = 1.38064852e-16 #cm^2 g s^-2 K^-1      # Boltzman constant
PC = 3.0857e18 #cm                         # 1 parsec
AU = 1.49597871e13 #cm                     # 1 astronomical unit

# code units
unit_d=1.66e-24
unit_t=3.004683525921981e15
unit_l=3.08567758128200e+18
unit_v=unit_l/unit_t

data = visu_ramses.load_snapshot(out_end)
for key in data["stellars"].keys():
    data["data"]["stellar_"+key] = data["stellars"][key]
for key in ['x', 'y', 'z']:
    data["data"]["sink_"+key] = data["sinks"][key]

x      = data["data"]["x"]
y      = data["data"]["y"]
z      = data["data"]["z"]
dx     = data["data"]["dx"]
rho    = data["data"]["density"]
p      = data["data"]["pressure"] * unit_d * unit_l**2 / unit_t**2
cs2 = p/(rho * unit_d)
temperature = cs2 * 2.37 * MH /KB

xmin = np.amin(x-0.5*dx)
xmax = np.amax(x+0.5*dx)
ymin = np.amin(y-0.5*dx)
ymax = np.amax(y+0.5*dx)
zmin = np.amin(z-0.5*dx)
zmax = np.amax(z+0.5*dx)

nx  = 2**7
dpx = (xmax-xmin)/float(nx)
dpy = (ymax-ymin)/float(nx)
dpz = (zmax-zmin)/float(nx)
xpx = np.linspace(xmin+0.5*dpx,xmax-0.5*dpx,nx)
ypx = np.linspace(ymin+0.5*dpy,ymax-0.5*dpy,nx)
zpx = np.linspace(zmin+0.5*dpz,zmax-0.5*dpz,nx)
grid_x, grid_y, grid_z = np.meshgrid(xpx,ypx,zpx)
points = np.transpose([x,y,z])
z1 = griddata(points,rho,(grid_x,grid_y, grid_z),method='nearest')
z2 = griddata(points,temperature,(grid_x,grid_y, grid_z),method='nearest')

fig, ax = plt.subplots(nrows=1, ncols=2, figsize=(10, 5))

im1 = ax[0].imshow(z1[:,:,int(2**7/2.)], origin="lower", aspect='equal', extent=[xmin, xmax, ymin, ymax])
im2 = ax[1].imshow(z2[:,:,int(2**7/2.)], origin="lower", aspect='equal', extent=[xmin, xmax, ymin, ymax])

plt.colorbar(im1, ax=ax[0], label='Density [H/cc]')
plt.colorbar(im2, ax=ax[1], label='temperature [K]')

ax[0].scatter(data["data"]["sink_x"],[data["data"]["sink_y"]], s = 20, marker='x')
ax[1].scatter(data["data"]["sink_x"],[data["data"]["sink_y"]], s = 20, marker='x')

fig.savefig('stellar_spawn.pdf', bbox_inches="tight")

visu_ramses.check_solution(data["data"],'stellar_spawn',overwrite=False)
