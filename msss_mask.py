#!/usr/bin/python

# fill a mask based on skymodel
# Usage: ./msss_mask.py mask-file skymodel
# Example: ./msss_mask.py wenss-2048-15.mask skymodel.dat
# Bugs: fdg@mpa-garching.mpg.de

# version 0.2
#
# FIXED BUG
# * if a source is outside the mask, the script ignores it
# * if a source is on the border, the script draws only the inner part
# * can handle skymodels with different headers
#
# KNOWN BUG
# * not works with single line skymodels, workaround: add a fake source outside the field

import pyrap.images as pi
import sys
import numpy as np
import os
import random
import re

pad = 500. # increment in maj/min axes [arcsec]

# Converts an hms format RA to decimal degrees
def hmstora(rah,ram,ras):
    """Convert RA in hours, minutes, seconds format to decimal
    degrees format.

    Keyword arguments:
    rah,ram,ras -- RA values (h,m,s)

    Return value:
    radegs -- RA in decimal degrees

    """
    hrs = (float(rah)+(float(ram)/60)+(float(ras)/3600.0)) % 24

    return 15*hrs

# Converts a dms format Dec to decimal degrees 
def dmstodec(decd,decm,decs):
    """Convert Dec in degrees, minutes, seconds format to decimal
    degrees format.

    Keyword arguments:
    decd,decm,decs -- list of Dec values (d,m,s)

    Return value:
    decdegs -- Dec in decimal degrees

    """
    if decd < 0:
        decm = -1*decm
        decs = -1*decs

    decdegs = float(decd)+(float(decm)/60)+(float(decs)/3600.0)

    if abs(decdegs) > 90:
        raise ValueError

    return decdegs

# Read skymodel header and return an array of names and an array of types fot loadtxt
def read_header(catalogue):
	names = []
	formats = []
	f = open(catalogue, 'r')
	header = f.readline()
	header = re.sub(r'\s', '', header)
	header = re.sub(r'format=', '', header)
	headers = header.split(',')
	for h in headers:
		h = re.sub(r'=.*', '', h)
		if h == "Name":
			names.append('name')
			formats.append('S100')
		elif h == "Type":
			names.append('type')
			formats.append('S100')
		elif h == "Ra":
			names.append('ra')
			formats.append('S100')
		elif h == "Dec":
			names.append('dec')
			formats.append('S100')
		elif h == "MajorAxis":
			names.append('maj')
			formats.append(np.float/2) # fwhm -> radius
		elif h == "MinorAxis":
			names.append('min')
			formats.append(np.float/2) # fwhm -> radius
		elif h == "Orientation":
			names.append('pa')
			formats.append(np.float)
		else:
			names.append(h)
			formats.append('S100')
	
	return names, formats

#######################
mask_file = sys.argv[1]
catalogue = sys.argv[2]

# read catalogue
names, formats = read_header(catalogue)
types = np.dtype({'names':names,'formats':formats})
data = np.loadtxt(catalogue, comments='format', unpack=True, dtype=types, delimiter=',')

# read mask
mask = pi.image(mask_file, overwrite=True)
mask_data = mask.getdata()
xlen, ylen = mask.shape()[2:]
freq, stokes, null, null  = mask.toworld([0,0,0,0])

# check if a pixel belogs to a source
for source in data:
	print "Adding ", source['name']
	# convert ra and dec to rad
	hh,mm,ss = source['ra'].split(':')
	ra = hmstora(hh,mm,ss)*np.pi/180
	dd,mm,ss = source['dec'].split('.',2)
	dec = dmstodec(dd,mm,ss)*np.pi/180
	if source['type'] == 'GAUSSIAN':
		maj=(((source['maj']+pad))/3600.)*np.pi/180. # major radius (+pad) in rad
		min=(((source['min']+pad))/3600.)*np.pi/180. # minor radius (+pad) in rad
		pa=source['pa']*np.pi/180.
		if maj == 0 or min == 0: # wenss writes always 'GAUSSIAN' even for point sources -> set to wenss beam+pad
			maj=((54.+pad)/3600.)*np.pi/180.
               		min=((54.+pad)/3600.)*np.pi/180.
	elif source['type'] == 'POINT': # set to wenss beam+pad
		maj=(((54.+pad)/2.)/3600.)*np.pi/180.
		min=(((54.+pad)/2.)/3600.)*np.pi/180.
		pa=0.
	else:
		print "WARNING: unknown source type ("+source['type']+"), ignoring it."

	#print "Maj = ", maj*180*3600/np.pi, " - Min = ", min*180*3600/np.pi # DEBUG

	# define a small square around the source to look for it
	null,null,y1,x1 = mask.topixel([freq,stokes,dec-maj,ra-maj/np.cos(dec-maj)])
	null,null,y2,x2 = mask.topixel([freq,stokes,dec+maj,ra+maj/np.cos(dec+maj)])
	xmin = np.int(np.floor(np.min([x1,x2])))
	xmax = np.int(np.ceil(np.max([x1,x2])))
	ymin = np.int(np.floor(np.min([y1,y2])))
	ymax = np.int(np.ceil(np.max([y1,y2])))

	print ymin, ymax
	
	if xmin > xlen or ymin > ylen or xmax < 0 or ymax < 0:
		print "WARNING: source ", source['name'], "falls outside the mask, ignoring it."
		continue
	if xmax > xlen or ymax > ylen or xmin < 0 or ymin < 0:
		print "WARNING: source ", source['name'], "falls across map edge."
	
	for x in xrange(xmin, xmax):
		for y in xrange(ymin, ymax):
			# skip pixels outside the mask field
			if x > xlen or y > ylen or x < 0 or y < 0: continue
			# get pixel ra and dec in rad
			null, null, pix_dec, pix_ra = mask.toworld([0,0,y,x])
		
			X = (pix_ra-ra)*np.sin(pa)+(pix_dec-dec)*np.cos(pa); # Translate and rotate coords.
			Y = -(pix_ra-ra)*np.cos(pa)+(pix_dec-dec)*np.sin(pa); # to align with ellipse
			if X**2/maj**2+Y**2/min**2 < 1:
				mask_data[0,0,y,x] = 1
#				mask_data[0,1,y,x] = 1
#				mask_data[0,2,y,x] = 1
#				mask_data[0,3,y,x] = 1

mask.putdata(mask_data)
