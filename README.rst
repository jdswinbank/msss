=========================================
Techniques for quick MSSS data processing
=========================================
-------------------------
John Swinbank, March 2012
-------------------------

This document describes scripts and techniques which may be used for rapidly
processing data as part of the ongoing MSSS commissioning effort.

Basic calibration workflow
--------------------------

Processing a single snapshot
++++++++++++++++++++++++++++

This section describes the ``run_calibrate.sh`` script. This is based on code
originally written by Tom Hassall: see `the report by Bell, Hassall and
Heald
<http://www.lofar.org/operations/lib/exe/fetch.php?media=msss:msss_week8_bell-hassall-heald.pdf>`_.
It has been substantially modified and updated.

``run_calibrate.sh`` processes a single band (in the following examples, we'll
use ``6``) of an observation ("obs_id"; in the following examples, we'll use
``L42025``), making it easy to:

- (Optionally) copy the relevant data from the ``/data/scratch/pipeline``
  directories on the compute nodes (where it is stored after standard
  processing) to your work area.

- Use ``BBS`` to determine gain solutions for the calibrator beam.

- Eliminate aberrant points in those solutions using ``edit_parmdb.py``.

- Make diagnostic plots of the results with ``solplot.py``.

- Transfer the gain solutions to the target field.

- Combine all subbands using ``NDPPP``.

- Flag the combined data with ``rficonsole``.

- Perform phase-only calibration of the result with ``BBS``.

- (Optionally) detect bad stations using the scripts developed by `Martinez
  and Pandey
  <http://www.lofar.org/operations/lib/exe/fetch.php?media=msss:pandeymartinez-week9-v1p1.pdf>`_.

- (Optionally) remove bad (or other, user-specified) stations from the data.

At this point the data is ready for imaging using ``awimager``, ``casapy`` or
another tool of your choice.

``run_calibrate.sh`` is available on CEP2 as
``~swinbank/msss/run_calibrate.sh``. Running it with no arguments will produce
a usage message::

  $ ~swinbank/msss/run_calibrate.sh
  Usage:
      /home/swinbank/msss/run_calibrate.sh [options] <obs_id> <beam> <band> <skyModel> <calModel>

  Options with string arguments:
      -o   Output filename (default: ${obs_id}_SAP00${beam}_BAND${band}.MS.flag)
      -a   Parset for calibration of calibrator (default: cal.parset)
      -g   Parset applying gain calibration to target (default: correct.parset)
      -p   Parset for phase-only calibration of target (default: phaseonly.parset)
      -d   Dummy sky model for use in applying gains (default: /home/hassall/MSSS/dummy.model)
      -s   Flag a specific station in the output

  Options which take no argument:
      -c   Collect data prior to processing
      -f   Automatically identify & flag bad stations
      -w   Overwrite output file if it already exists
      -h   Display this message

  Example:
      /home/swinbank/msss/run_calibrate.sh L42025 0 06 sky.model 3c295.model

The five parameters in ``<>`` angle brackets are all required, and must be
specified in the order shown. Note that they must come *after* any optional
arguments, as shown in the usage message. Filenames are specified relative to
the current working directory: you might well find it safest to use full paths
(``/home/swinbank/msss/sky.model`` etc) to avoid confusion. It is hoped that
``obs_id``, ``beam`` and ``band`` are self-explanatory. ``skyModel`` is a
model (in ``makesourcedb`` format)  which will be used when performing
phase-only calibration on the target field. ``calModel`` is a model used for
calibrating the calibrator field.

By default, the script will look for configuration parsets for ``BBS`` in your
current working directory: ``cal.parset``, ``correct.parset`` and
``phaseonly.parset`` as per the usage message. You may specify alternative
parsets using the command line options if required (eg ``-p
/home/swinbank/alternative.parset``).

If ``-c`` is specified, the script will attempt to find the data required and
copy it to your current working directory before processing. It is suggested
that you use this option the first time you run this script, then, once you
have a copy of the data, you don't need this option again. Until you delete
it by mistake...

The ``-s`` option enables you to remove specific stations from the output. It
may be specified multiple times and the results are cumulative.

If ``-f`` is specified, the script will automatically attempt to identify and
remove bad stations using the code developed by Martinez and Pandey. It is
cumulative with ``-s``, above. For example, on one particular dataset::

  $ ~swinbank/msss/run_calibrate.sh -s CS001LBA -s CS002LBA -f [...]

causes ``CS001LBA``, ``CS002LBA``, ``CS013LBA``, ``CS030LBA`` and ``CS032LBA``
all to be removed: the first two because the user specified them, the remainder
because they were automatically identified as bad. Note that the automatic
identification of bad stations can be slow: you might wish to specify ``-f``
on your first run through a given dataset, take note of the stations it
identifies as bad, and remove them with ``-s`` on subsequent runs.

By default, the script will stop if its output location already exists. If you
would like to automatically remove and replace pre-existing output data,
specify ``-w``.

Note that it is generally a good idea to keep a log of exactly what processing
you've done. ``run_calibrate.sh`` will create a ``log`` directory in your
current working directory into which it will place the output from ``BBS`` and
other long running processes. It will also send progress information to
standard output. You may wish to send this progress information to a log file
of your own for future reference. Try something like::

  $ ~swinbank/msss/run_calibrate.sh [...] | tee log-`date +%F-%X`

Finally: where possible, the various tasks are performed in parallel. That
means (for example) that all the calibrator subbands are procesed
simultaneously.  Assuming you're processing a 10-subband band on a CEP2
compute node, this is good news: you should see a tenfold speedup relative to
processing each subband sequentially! If you attempt to use this script to
process very many subbands, or run on a machine with much more constrainted
resources than the CEP2 nodes, you might need to rethink this strategy.

Processing multiple snapshots
+++++++++++++++++++++++++++++

The above should make it relatively straightforward to rapidly process a
single snapshot. However, a standard MSSS observation will consist of multiple
snapshots which are combined prior to imaging. Luckily, rapidly processing
them all at once with the same configuration is (fairly) straightforward. A
suggested workflow follows. Note that this assumes you are running ``bash``,
like all right-thinking people: translation to ``tcsh`` is left as an exercise
for the reader!

First, choose your compute node, and create a working directory on it::

  $ ssh locus024
  $ mkdir -p /data/scratch/swinbank/L227+69
  $ cd /data/scratch/swinbank/L227+69

In that directory, place all the skymodels and parsets you'll need to run the
``run_calibrate.sh`` script. Then, create sub-directories named for each of
the obsids that you intend to process::

  $ mkdir L41961 L41969 L41977 L41985 L41993 ...

Now you can run the ``run_calibrate.sh`` in each of those directories in turn
by means of a single shell command::

  $ for dir in L*; do cd $dir && ~swinbank/msss/run_calibrate.sh -c \
    -f -a ../cal.parset  -g ../correct.parset -p ../phaseonly.parset\
    $dir 0 06 ../sky.model ../cal.model ; done

That's fine in so far as it goes, but if you're really impatient you can
actually process multiple observations in parallel::

  $ for dir in L*; do echo $dir; done |                                  \
    xargs -Idir -n1 -P4 sh -c 'cd dir && ~swinbank/msss/run_calibrate.sh \
    -c -f -a ../cal.parset  -g ../correct.parset -p ../phaseonly.parset  \
    dir 0 06 ../sky.model ../cal.model'

Phew! That is, admittedly, something of a mouthful, but your data will likely
be processed by the time you've got yourself a cup of coffee. Note that we
limit the above to processing only 4 snapshots at a time: that should still be
plenty to saturate a compute node. You an adjust the number of snapshots
processed simultaneously by changing the ``-P4`` parameter.

Concatenating snapshots
+++++++++++++++++++++++

Of course, you can now go ahead and image each of those snapshots
independently. However, you may well find it desirable to concatenate them
together and image them as one unit. You can do this concatenation yourself
(but note that `Bonafede & Macario
<http://www.lofar.org/operations/lib/exe/fetch.php?media=msss:bonafede_macario_w10.pdf>`_
warn against using ``casapy``), but a simple script is available to make your
life even easier::

  $ ~swinbank/msss/concat.py <output.MS> <input1.MS> ... [inputN.MS]

You must specify an output MeasurementSet (which will be created for you) and
at least one input. Following our example above, we could write::

  $ ~swinbank/msss/concat.py final.MS L4*/*MS.flag

To concatenate all the snapshots we have calibrated. You can then go ahead and
image ``final.MS`` using ``casapy``, ``awimager``, etc.

Timing
++++++

Processing all nine snapshots targeting L227+69 (L41961, L41969, L41977,
L41985, L41993, L42001, L42009, L42017 and L42025) through `run_calibrate.sh`,
including collecting all the data (``-c``) and automatically identifying bad
stations (``-f``) took a wall-clock time of 14 minutes 20 seconds. The total
CPU time, real+user, was nearer 106 minutes, thus demonstrating the advantages
of parallelization! Note that the processing time can be heavily dependent on
the BBS configuration used, in particular the complexity of the sky model used
when performing the phase-only calibration step.

Concatenating the results of all nine snapshots took a further 20 seconds.

Testimonials
++++++++++++

"I should really try using that script" -- Jess Broderick

Tapering skymodels
------------------

Another script which may be of interest is ``~swinbank/msss/taper.py``. It
enables you to easily apply a Gaussian taper to a sky model, so that (for
example) at the centre of your image the model includes all sources, however
fait, but around the edges only the brightest sources are included. It is run
as follows::

  $ ~swinbank/msss/taper.py
  taper.py -- Applies Gaussian taper to skymodel

  Usage: taper.py <flux_limit> <fwhm> <ra> <dec> < [input] > [output]
  Reads input sky model from stdin, outputs to stdout.

You must supply four positional arguments. ``flux_limit`` specifies the
minimum flux which will be included at the edge of the taper: note that *all*
sources at the centre will be included). ``fwhm`` specifies the full-width at
half-maximum of the tapering. ``ra`` and ``dec`` specify the position of the
centre of the tapering function: these can be supplied in any format which is
understood by ``casacore`` (so you can, for example, copy and paste from your
skymodel file).

Input is read from standard input, and the result is written to standard out.
You can therefore use the redirection facilities in your shell (``<`` and
``>``) to arrange for the tapered model to be saved to an appropriate
location.

Testimonials
++++++++++++

"It works, but it didn't make much difference to the RMS" -- Antonia Rowlinson

Extra: Problems with X11 forwarding
-----------------------------------

If you are using a Mac to connect to CEP, you might experience a problem where
your X11 forwarding appears to stop working randomly (that is, if you type
``xterm``, rather than having a terminal appear you get a message to the
effect ``Xt error: Can't open display`` or similar). This can be a problem, as
various MSSS tools check for an X11 connection, even if they don't actually
display anything using it, and therefore start breaking spontaneously. Which
is sad.

You should be able to work around this by setting the ``ForwardX11Timeout``
option to ``596h`` when running SSH *on your Mac*. For example::

  $ ssh -o ForwardX11TImeout=596h locus024

You may wish to add this to your ``~/.ssh/config`` file to avoid typing it
every time -- figuring out the relevant syntax is left as an exercise for the
reader!

You might also have some luck by using "trusted" X11 forwarding. Enable this
by using ``-Y`` in the place of ``-X`` in your SSH command line.

Finally
-------

Your contributions, suggestions, bug-fixes, etc to the scripts mentioned in
this document are, of course, welcomed. Mail me:
``swinbank@transientskp.org``.
