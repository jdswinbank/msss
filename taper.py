#!/usr/bin/env python

import sys
import fileinput
import math
from cStringIO import StringIO
from pyrap.measures import measures

EPOCH = 'J2000'

def gaussian_cutoff(limit, fwhm, ra, dec):
    limit = float(limit)
    fwhm = float(fwhm)
    dm = measures()
    centre = dm.direction(EPOCH, ra, dec)
    constant = -4 * math.log(2) / float(fwhm)**2
    def flux_limit(ra, dec):
        target = dm.direction(EPOCH, ra, dec)
        distance = dm.separation(centre, target).get_value()
        return limit * (1 -  math.exp(constant * distance**2))
    return flux_limit

def parse_skymodel(calculate_limit):
    output = StringIO()
    for line in fileinput.input("-"):
        if "format" in line:
            output.write(line)
            continue
        ra = line.split(',')[2]
        dec = line.split(',')[3]
        flux = float(line.split(',')[4])
        limiting_flux = calculate_limit(ra, dec)
        if flux > limiting_flux:
            output.write(line)
    return output.getvalue()

if __name__ == "__main__":
    try:
        calculate_limit = gaussian_cutoff(*sys.argv[1:5])
        print parse_skymodel(calculate_limit)
    except Exception, e:
        print "taper.py -- Applies Gaussian taper to skymodel\n"
        print "Usage: taper.py <flux_limit> <fwhm> <ra> <dec> < [input] > [output]"
        print "Reads input sky model from stdin, outputs to stdout.\n"
        print >>sys.stderr, "Error: %s" % (str(e),)
