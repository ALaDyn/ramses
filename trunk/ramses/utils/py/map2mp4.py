#!/usr/bin/env python
 
import sys
import numpy
import os
import warnings
import fortranfile
from argparse import ArgumentParser
import subprocess
import matplotlib
# try to use agg backend as it allows to render movies without X11 connection                  
try:
	matplotlib.use('agg')
except:
	pass
from matplotlib import pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.collections import PatchCollection
from scipy import signal
import multiprocessing as mp
import time

from numpy.polynomial.polynomial import polyfit

def a2z(a):
	z = 1./a-1.
	return z

def label(xy, text):
	y = xy[1] + 15 # shift y-value for label so that it's below the artist
	plt.text(xy[0], y, text, ha="center",  size=14, color='white')

def load_map(args,k,i,mapkind=None):
	if mapkind is None:
		kind = [item for item in args.kind.split(' ')]
		# define map path
		map_file = "%s/movie%d/%s_%05d.map" % (args.dir, int(args.proj), kind[k], i)
	else:
		map_file = "%s/movie%d/%s_%05d.map" % (args.dir, int(args.proj), mapkind, i)
		
	# read image data
	f = fortranfile.FortranFile(map_file)
	[t, dx, dy, dz] = f.readReals('d')
	[nx,ny] = f.readInts()
	dat = f.readReals()
	f.close()

	return dat

def load_sink(dir,i):
	# setting dummy values
	sink_id, sink_m, sink_x, sink_y, sink_z = [-1 for a in xrange(5)]
	# defnining sink path
	sink_file = "%s/movie1/sink_%05d.txt" % (dir, i)
	try:
		with warnings.catch_warnings(): # load sink id, mass and position
			warnings.simplefilter("ignore")
			sink_id, sink_m,sink_x,sink_y,sink_z = numpy.loadtxt(sink_file, delimiter=',',usecols=(0,1,2,3,4),unpack=True)
			plot_sinks = True
	except ValueError: # catch if no sinks exist (for sink creation)
		plot_sinks = False
	except IOError: # sink file missing
		print "No sink file"
		plot_sinks = False
	
	return plot_sinks, sink_id, sink_m, [sink_x, sink_y, sink_z]

def load_namelist_info(args):
	proj_list = [int(item) for item in args.proj.split(' ')]
	proj_ind = int(proj_list[0])-1
	
	if args.namelist == '':
		namelist = args.dir + '/output_00002/namelist.txt'
	else: # non-default namelist
		namelist = args.namelist

	try:
		nmlf = open(namelist)
	except IOError:
		print "No namelist found! Aborting!"
		sys.exit()
	
	sink_flag = False
	cosmo = False
	# Loading parameters from the namelist
	for i, line in enumerate(nmlf):
		if line.split('=')[0] == 'xcentre_frame':
			xcentre_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'ycentre_frame':
			ycentre_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'zcentre_frame':
			zcentre_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'deltax_frame':
			deltax_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'deltay_frame':
			deltay_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'deltaz_frame':
			deltaz_frame = numpy.array(line.split('=')[1].split(','),dtype=float)
		if line.split('=')[0] == 'boxlen':
			boxlen = float(line.split('=')[1])
		if line.split('=')[0] == 'proj_axis':
			proj_axis = line.split('=')[1]
		if line.split('=')[0] == 'nw_frame':
			nx = int(line.split('=')[1])
		if line.split('=')[0] == 'nh_frame':
			ny = int(line.split('=')[1])
		if line.split('=')[0] == 'imovout':
			max_iter = int(line.split('=')[1])
		if (line.split('=')[0] == 'sink') and (line.split('=')[1][:-1] == '.true.'):
			sink_flag = True
		if (line.split('=')[0] == 'cosmo') and (line.split('=')[1][:-1] == '.true.'):
			cosmo = True
			boxlen = 1.
		if line.split('=')[0] == 'levelmax_frame':
			levelmax = int(line.split('=')[1])

	return xcentre_frame, ycentre_frame, zcentre_frame, deltax_frame, deltay_frame, deltaz_frame, \
			boxlen, proj_axis, nx, ny, max_iter, sink_flag, cosmo, levelmax

def load_units(i, args):
	if type(args.proj) == str:
		proj_list = [int(item) for item in args.proj.split(' ')]
	else:
		proj_list = [args.proj]
	proj_ind = int(proj_list[0])-1

	infof = open('{dir}/movie{proj}/info_{num:05d}.txt'.format(dir=args.dir, proj=proj_list[0], num=i))
	for j, line in enumerate(infof):
		if j == 15:
			unit_l = float(line.split()[2])
		if j == 16:
			unit_d = float(line.split()[2])
		if j == 17:
			unit_t = float(line.split()[2])
		if j> 18:
			break
	unit_m = unit_d*unit_l**3/2e33 # in MSun

	return unit_l, unit_d, unit_t, unit_m

def make_image(i, args, proj_list, proj_axis, nx, ny, sink_flag, boxlen, xcentre_frame, ycentre_frame, zcentre_frame, deltax_frame, deltay_frame, deltaz_frame, kind, geo, cosmo, scale_l, cmin, cmax, levelmax):

	fig = plt.figure(frameon=False)
	fig.set_size_inches(nx/100*geo[1],ny/100*geo[0])

	unit_l, unit_d, unit_t, unit_m = load_units(i, args) # need to load units here due to cosmo

	for p in xrange(len(proj_list)):
		args.proj = proj_list[p]
		axis = proj_axis[args.proj]
		dat = load_map(args,p,i)
		if sink_flag:
			plot_sinks, sink_id, sink_m, sink_pos = load_sink(args.dir,i)
			if plot_sinks:
				sink_m = numpy.log10(sink_m*unit_m)
				sink_pos = [x/boxlen for x in sink_pos]
	
		infof = open("%s/movie%d/info_%05d.txt" % (args.dir, int(args.proj), i))
		for j, line in enumerate(infof):
			if cosmo:
				if j == 9: # instead of t we get the aexp
					a = float(line.split()[2])
			else:
				if j == 8:
					t = float(line.split()[2])
			if j > 9:
				break
	
		if kind[p] == 'dens':
			dat *= unit_d	# in g/cc
		if kind[p] in ["vx","vy","vz"]:
			dat *= (unit_l/unit_t)/1e5 # in km/s

		if(args.outfile==None):
			outfile="%s/pngs/%s_%05d.png" % (args.dir, kind[p], i/int(args.step)-int(args.fmin))
			if sum(geo)>2:
				outfile="%s/pngs/multi_%05d.png" % (args.dir, i/int(args.step)-int(args.fmin))
		else:
			outfile=args.outfile
		
		if(args.logscale):
			dat = numpy.array(dat)
			if(kind[p] == 'stars' or kind[p] == 'dm'):
				dat += 1e-12
		# Reshape data to 2d
		dat = dat.reshape(ny,nx)

		if (kind[p] == 'stars' or kind[p] == 'dm'): # PSF convolution
			kernel = numpy.outer(signal.gaussian(100,1),signal.gaussian(100,1))
			dat = signal.fftconvolve(dat, kernel, mode='same')

		rawmin = numpy.amin(dat)
		rawmax = numpy.amax(dat)

		# Bounds
		if args.min == None:
			plotmin = rawmin
		else:
			plotmin = float(args.min)

		if args.max == None:
			plotmax = rawmax
		else:
			plotmax = float(args.max)

		# Log scale?
		if(args.logscale and kind[p] not in ["vx","vy","vz"]): # never logscale for velocities
			dat = numpy.log10(dat)
			rawmin = numpy.log10(rawmin)
			rawmax = numpy.log10(rawmax)
			plotmin = numpy.log10(plotmin)
			plotmax = numpy.log10(plotmax)
		
		# Auto-adjust dynamic range?
		if(args.autorange):
			# Overrides any provided bounds
			NBINS = 200
			# Compute histogram
			(hist,bins) = numpy.histogram(dat, NBINS, (rawmin,rawmax), normed=True)
			chist = numpy.cumsum(hist); chist = chist / numpy.amax(chist)
			# Compute black and white point
			clip_k = chist.searchsorted(0.15)
			plotmin = bins[clip_k]
			plotmax = rawmax

		if args.poly > 0:
			p_min = 0.
			p_max = 0.
			for d in xrange(args.poly+1):
				p_min += cmin[p][d]*i**d
				p_max += cmax[p][d]*i**d
			
			plotmin = p_min
			plotmax = p_max
		
		if kind[p] in ["vx","vy","vz"]:
			plotmax=max(abs(rawmin),rawmax)
			plotmin=-plotmax
	
		# Plotting
		
		ax = fig.add_subplot(geo[0],geo[1],p+1)
		ax.axis([0,nx,0,ny])
		fig.add_axes(ax)

		if kind[p] == 'temp':
			cmap = 'jet'
		elif kind[p] in ["vx","vy","vz"]:
			cmap = 'RdBu_r'
		else:
			cmap=args.cmap_str
		im = ax.imshow(dat, interpolation = 'nearest', cmap = cmap,\
				vmin = plotmin, vmax = plotmax, aspect='auto')
		ax.tick_params(bottom='off', top='off', left='off', right='off') # removes ticks
		ax.tick_params(labelbottom='off', labeltop='off', labelleft='off', labelright='off') # removes ticks

		labels_color = 'w'
		if kind[p] == 'dens':
			labels_color = 'w'
		if kind[p] == 'temp':
			labels_color = 'k'

		if args.colorbar:
			cbaxes = fig.add_axes([1./geo[1]+p%geo[1]*1./geo[1]-0.05/geo[1],abs(p-geo[0]*geo[1]+1)/geo[1]*1./geo[0],0.05/geo[1],1./geo[0]])
			cbar = plt.colorbar(im, cax=cbaxes)
			cbar.solids.set_rasterized(True)
			bar_font_color = 'k'
			scolor = 'w'
			if kind[p] == 'dens':
				scolor = 'w'
				bar_font_color = 'r'
			if kind[p] == 'temp':
				scolor = 'k'
			cbar.ax.tick_params(width=0,labeltop='on',labelcolor=bar_font_color,labelsize=8,pad=-25)
		
		# magnetic field lines
		if kind[p] == 'pmag' and args.streamlines is True:
			if axis == 'x':
				dat_U = load_map(args,p,i,'byl').reshape(ny,nx)
				dat_V = load_map(args,p,i,'bzl').reshape(ny,nx)
			elif axis == 'y':
				dat_U = load_map(args,p,i,'bxl').reshape(ny,nx)
				dat_V = load_map(args,p,i,'bzl').reshape(ny,nx)
			elif axis == 'z':
				dat_U = load_map(args,p,i,'bxl').reshape(ny,nx)
				dat_V = load_map(args,p,i,'byl').reshape(ny,nx)
			pX = numpy.linspace( 0,nx,num=nx,endpoint=False )
			pY = numpy.linspace( 0,ny,num=ny,endpoint=False )
			ax.streamplot(pX,pY,dat_U,dat_V,density=0.25,color='w',linewidth=1.0)
		
		frame_centre_w = 0.0
		frame_centre_h = 0.0
		frame_delta_w = 0.0
		frame_delta_h = 0.0

		if not cosmo:
			a = 1.
		
		# Plotting sink
		if axis == 'x':
			w=1
			h=2
			for k in xrange(0,4):
				frame_centre_w += ycentre_frame[4*(proj_list[p]-1)+k]*a**k
				frame_centre_h += zcentre_frame[4*(proj_list[p]-1)+k]*a**k
				if k < 2:
					frame_delta_w += deltay_frame[2*(proj_list[p]-1)+k]/a**k
					frame_delta_h += deltaz_frame[2*(proj_list[p]-1)+k]/a**k

		elif axis == 'y':
			w=0
			h=2
			for k in xrange(0,4):
				frame_centre_w += xcentre_frame[4*(proj_list[p]-1)+k]*a**k
				frame_centre_h += zcentre_frame[4*(proj_list[p]-1)+k]*a**k
				if k < 2:
					frame_delta_w += deltax_frame[2*(proj_list[p]-1)+k]/a**k
					frame_delta_h += deltaz_frame[2*(proj_list[p]-1)+k]/a**k

		else:
			w=0
			h=1
			for k in xrange(0,4):
				frame_centre_w += xcentre_frame[4*(proj_list[p]-1)+k]*a**k
				frame_centre_h += ycentre_frame[4*(proj_list[p]-1)+k]*a**k
				if k < 2:
					frame_delta_w += deltax_frame[2*(proj_list[p]-1)+k]/a**k
					frame_delta_h += deltay_frame[2*(proj_list[p]-1)+k]/a**k
		
		if (sink_flag and plot_sinks):
			area_sink = 10
			if (args.true_sink):
				r_sink = 0.5**(levelmax)*4*boxlen*nx/frame_delta_w*1.5 # r_sink = 1/2**(level_max) * ir_cloud(default=4) * boxlen; then convert into pts
				area_sink = r_sink*r_sink
				ax.scatter((sink_pos[w]-frame_centre_w/boxlen)/(frame_delta_w/boxlen/2)*nx/2+nx/2,\
						   (sink_pos[h]-frame_centre_h/boxlen)/(frame_delta_h/boxlen/2)*ny/2+ny/2,\
						   marker='o',facecolor='none',edgecolor='0.0',s=area_sink, lw=1) # s takes area in pts
			else:
				ax.scatter((sink_pos[w]-frame_centre_w/boxlen)/(frame_delta_w/boxlen/2)*nx/2+nx/2,\
						   (sink_pos[h]-frame_centre_h/boxlen)/(frame_delta_h/boxlen/2)*ny/2+ny/2,\
						   marker='o',c='k',s=area_sink)

		if not args.clean_plot:
			patches = []
			barlen_px = args.barlen*scale_l*nx/(float(boxlen)*unit_l*3.24e-19*frame_delta_w/float(boxlen))
			rect = mpatches.Rectangle((0.025*nx,0.025*ny), barlen_px, 10)
			ax.text(0.025+float(barlen_px/nx/2), 0.025+15./ny,"%d %s" % (args.barlen, args.barlen_unit),
								verticalalignment='bottom', horizontalalignment='center',
								transform=ax.transAxes,
								color=labels_color, fontsize=18)
			patches.append(rect)
			
			if cosmo:
				ax.text(0.05, 0.95, 'a={a:.3f}'.format(a=a), # aexp instead of time
								verticalalignment='bottom', horizontalalignment='left',
								transform=ax.transAxes,
								color=labels_color, fontsize=18)
			else:
				t *= unit_t/86400/365.25 # time in years
				if (t >= 1e3 and t < 1e6):
					scale_t = 1e3
					t_unit = 'kyr'
				elif (t > 1e6 and t < 1e9):
					scale_t = 1e6
					t_unit = 'Myr'
				elif t > 1e9:
					scale_t = 1e9
					t_unit = 'Gyr'
				else:
					scale_t = 1
					t_unit = 'yr'

				ax.text(0.05, 0.95, '%.1f %s' % (t/scale_t, t_unit),
								verticalalignment='bottom', horizontalalignment='left',
								transform=ax.transAxes,
								color=labels_color, fontsize=18)

			collection = PatchCollection(patches, facecolor=labels_color)
			ax.add_collection(collection)
	
	# corrects window extent
	plt.subplots_adjust(left=0., bottom=0., right=1., top=1., wspace=0., hspace=0.)
	plt.savefig(outfile,dpi=100)
	plt.close(fig)

	return

def fit_min_max(args,p,max_iter,proj_list,proj_axis):
	mins = numpy.array([])
	maxs = numpy.array([])
	
	kind = [item for item in args.kind.split(' ')]
	
	for i in xrange(int(args.fmin)+int(args.step),max_iter+1,int(args.step)):
		args.proj = proj_list[p]
		axis = proj_axis[args.proj]
		dat = load_map(args,p,i)
		unit_l, unit_d, unit_t, unit_m = load_units(i, args)

		if kind[p] == 'dens':
			dat *= unit_d	# in g/cc
		if kind[p] in ['vx','vy','vz']:
			dat *= (unit_l/unit_t)/1e5 # in km/s
		if kind[p] in ['stars','dm']:
			dat += 1e-12
		
		if args.logscale:
			mins = numpy.append(mins,numpy.log10(numpy.amin(dat)))
			maxs = numpy.append(maxs,numpy.log10(numpy.amax(dat)))
		else:
			mins = numpy.append(mins,numpy.amin(dat))
			maxs = numpy.append(maxs,numpy.amax(dat))
		
	ii = range(int(args.fmin)+int(args.step),max_iter+1,int(args.step))
	cmin = polyfit(ii,mins,args.poly)	
	cmax = polyfit(ii,maxs,args.poly)

	return p, cmin, cmax

def main():

	# Parse command line arguments
	parser = ArgumentParser(description="Script to create RAMSES movies")
	parser.add_argument("-l","--logscale",dest="logscale", action="store_true", default=False, \
	    help="use log color scaling [%(default)s]")
	parser.add_argument("-m","--min",  dest="min", metavar="VALUE", \
			help='min value', default=None)
	parser.add_argument("-M","--max",  dest="max", metavar="VALUE", \
			help='max value', default=None)
	parser.add_argument("-f","--fmin",  dest="fmin", metavar="VALUE", \
			help='frame min value [%(default)d]', default=0, type=int)
	parser.add_argument("-F","--fmax",  dest="fmax", metavar="VALUE", \
			help='frame max value [%(default)d]', default=-1, type=int)
	parser.add_argument("-d","--dir", dest="dir", \
			help='map directory [current working dir]', default=os.environ['PWD'], metavar="VALUE")
	parser.add_argument("-p","--proj", dest="proj", default='1', type=str, \
			help="projection index [%(default)s]")
	parser.add_argument("-s","--step", dest="step", \
			help="framing step [%(default)d]", default=1, type=int)
	parser.add_argument('-k','--kind', dest="kind", \
			help="kind of plot [%(default)s]", default='dens')	
	parser.add_argument('-a','--autorange',dest='autorange', action='store_true', \
	    help='use automatic dynamic range (overrides min & max) [%(default)s]', default=False)
	parser.add_argument('--clean_plot',dest='clean_plot', action='store_true', \
	    help='do not annotate plot with bar and timestamp [%(default)s]', default=False)
	parser.add_argument('-c','--colormap',dest='cmap_str', metavar='CMAP', \
	    help='matplotlib color map to use [%(default)s]', default="bone")
	parser.add_argument('-b','--barlen',dest='barlen', metavar='VALUE', \
	    help='length of the bar (specify unit!) [%(default)d]', default=5, type=float)
	parser.add_argument('-B','--barlen_unit',dest='barlen_unit', metavar='VALUE', \
	    help='unit of the bar length (AU/pc/kpc/Mpc) [%(default)s]', default='kpc')
	parser.add_argument('-g','--geometry',dest='geometry', metavar='VALUE', \
	    help='montage geometry "rows cols" [%(default)s]', default="1 1")
	parser.add_argument("-o","--output",  dest="outfile", metavar="FILE", \
			help='output image file [<map_file>.png]', default=None)
	parser.add_argument('--nocolorbar',dest='colorbar', action='store_false', \
			help='add colorbar [%(default)s]', default=True)
	parser.add_argument('-n','--ncpu',dest='ncpu', metavar="VALUE", type=int, \
			help='number of CPUs for multiprocessing [%(default)d]', default=1)
	parser.add_argument('-P','--poly',dest='poly', metavar="VALUE", type=int, \
			help='polynomial degree for fitting min and max [off]', default=-1)
	parser.add_argument('-N','--namelist',dest='namelist', metavar="VALUE", type=str, \
			help='path to namelist, if empty take default [%(default)s]', default='')
	parser.add_argument('-r','--true_sink',dest='true_sink', action='store_true', \
			help='plot true sink radius as a circle [%(default)s]', default=False)
	parser.add_argument('-S','--streamlines',dest='streamlines', action='store_true', \
			help='overplot streamlines [%(default)s]', default=False)

	args = parser.parse_args()

	proj_list = [int(item) for item in args.proj.split(' ')]
	geo = [int(item) for item in args.geometry.split(' ')]
	kind = [item for item in args.kind.split(' ')]

	if args.barlen_unit == 'pc':
		scale_l = 1e0
	elif args.barlen_unit == 'kpc':
		scale_l = 1e3
	elif args.barlen_unit == 'Mpc':
		scale_l = 1e6
	elif args.barlen_unit == 'AU':
		scale_l = 1./206264.806
	else:
		print 'Wrong length unit!'
		sys.exit()

	proj_ind = int(proj_list[0])-1
	sink_flag = False
	
	# load basic info once, instead of at each loop
	xcentre_frame, ycentre_frame, zcentre_frame, deltax_frame, deltay_frame, deltaz_frame,\
			boxlen, proj_axis, nx, ny, max_iter, sink_flag, cosmo, levelmax = load_namelist_info(args)

	if (int(args.fmax) > 0):
		max_iter=int(args.fmax)
	else:
		from glob import glob
		args.fmin=min([filter(lambda x: x.isdigit(), y.split('/')[-1]) for y in glob('%s/movie1/info_*.txt' % args.dir)])
		max_iter=int(max([filter(lambda x: x.isdigit(), y.split('/')[-1]) for y in glob('%s/movie1/info_*.txt' % args.dir)]))


	# Progressbar imports
	try:
		from widgets import Percentage, Bar, ETA
		from progressbar import ProgressBar
		progressbar_avail = True
	except ImportError:
		progressbar_avail = False


	# for each projection fit mins and maxs with polynomial
	cmins = numpy.zeros(len(proj_list)*(args.poly+1)).reshape(len(proj_list),args.poly+1)
	cmaxs = numpy.zeros(len(proj_list)*(args.poly+1)).reshape(len(proj_list),args.poly+1)
	
	if args.poly > 0:
		if args.ncpu > 1:
			results = []
			pool = mp.Pool(processes=min(args.ncpu,len(proj_list)))
			
			results = [pool.apply_async(fit_min_max, args=(args,p,max_iter,proj_list, proj_axis,)) for p in xrange(len(proj_list))]
			pool.close()
			pool.join()
			output = [p.get() for p in results]
			
			for p in xrange(len(output)): # just for safety if executed not in order
				for d in xrange(len(proj_list)):
					if output[p][0] == d:
						cmins[d]=output[p][1]
						cmaxs[d]=output[p][2]
			
		elif args.ncpu == 1:
			if progressbar_avail:
				widgets = ['Working...', Percentage(), Bar(marker='='),ETA()]
				pbar = ProgressBar(widgets=widgets, maxval = len(proj_list)).start()
			else:
				print 'Working!'

			for d in xrange(len(proj_list)):
				cmins[d], cmaxs[d] = fit_min_max(args,p,max_iter,proj_list, proj_axis)
				if progressbar_avail:
					pbar.update(d+1)
			
			if progressbar_avail:
				pbar.finish()

		else:
			print 'Wrong number of CPUs! Exiting!'
			sys.exit()

		print 'Polynomial coefficients fitted!'


	# creating images
	if progressbar_avail:
	  widgets = ['Working...', Percentage(), Bar(marker='#'),ETA()]
	  pbar = ProgressBar(widgets=widgets, maxval = max_iter+1).start()
	else:
		print 'Working!'
	
	if not os.path.exists("%s/pngs/" % (args.dir)):
		os.makedirs("%s/pngs/" % (args.dir))

	if args.ncpu > 1:
		results = []
		pool = mp.Pool(processes=args.ncpu)
		for i in xrange(int(args.fmin)+int(args.step),max_iter+1,int(args.step)):
			results.append(pool.apply_async(make_image, args=(i, args, proj_list, proj_axis, nx, ny, sink_flag, boxlen, xcentre_frame, ycentre_frame, zcentre_frame, deltax_frame, deltay_frame, deltaz_frame, kind, geo, cosmo, scale_l, cmins, cmaxs, levelmax,)))
		while True:
			inc_count = sum(1 for x in results if not x.ready())
			if inc_count == 0:
				break

			if progressbar_avail:
				pbar.update(max_iter+1-inc_count)
			time.sleep(.1)

		pool.close()
		pool.join()

	elif args.ncpu == 1:
		for i in xrange(int(args.fmin)+int(args.step),max_iter+1,int(args.step)):
			make_image(i, args, proj_list, proj_axis, nx, ny, sink_flag, boxlen, xcentre_frame, ycentre_frame, zcentre_frame,deltax_frame, deltay_frame, deltaz_frame, kind, geo, cosmo, scale_l, cmins, cmaxs, levelmax)
			if progressbar_avail:
				pbar.update(i)

	else:
		print 'Wrong number of CPUs! Exiting!'
		sys.exit()

	if progressbar_avail:
			pbar.finish()


	# movie name for montage
	if sum(geo) > 2:
		frame = "{dir}/pngs/multi_%05d.png".format(dir=args.dir)
		mov = "{dir}/multi.mp4".format(dir=args.dir)
	else:
		frame = "{dir}/pngs/{kind}_%05d.png".format(dir=args.dir,kind=args.kind)
		mov = "{dir}/{kind}{proj}.mp4".format(dir=args.dir, kind=args.kind, proj=args.proj)
	
	print 'Calling ffmpeg!'
	subprocess.call("ffmpeg -loglevel quiet -i {input} -y -vcodec h264 -pix_fmt yuv420p  -r 25 -qp 15 {output}".format(input=frame, output=mov), shell=True)
	print 'Movie created! Cleaning up!'
	subprocess.call("rm {dir}/pngs -r".format(dir=args.dir), shell=True)
	subprocess.call("chmod a+r {mov}".format(mov=mov), shell=True)

if __name__ == '__main__':
	main()

