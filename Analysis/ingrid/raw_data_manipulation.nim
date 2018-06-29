## this script performs the raw data manipulation of a given run or list of runs
## and outputs the resulting data to a HDF5 file
## steps which are performed
## - reading all data*.txt and data*.txt-fadc files and writing them to a
##   HDF5 file, one group for each run
## - calculating the occupancy of each run
## - calculating the num_pix / event histogram
## - caluclating the FADC signal depth / event histogram
## - calculate the ToT per pixel histogram

## standard lib
import os
import re
import sequtils, future
import algorithm
import tables
import times
import threadpool
import memfiles
import strutils, strformat
import docopt
import typetraits
import sets
import macros
#import nimprof

# InGrid-module
import helper_functions
import tos_helper_functions
import fadc_helper_functions
import ingrid_types
#import reconstruction

# other modules
import seqmath
import nimhdf5
import arraymancer

# global experimental pragma to use parallel: statement in readRawInGridData()
{.experimental.}

## TODO:
## change the we write to H5 to appropriate types, e.g.
## x / y pixel coordinates may as well be written as uint8
## FADC raw as uint16
## all flags as uint8
## ToT values as uint16
## hits as uint16

const FILE_BUFSIZE = 10000

let doc = """
InGrid raw data manipulation.

Usage:
  raw_data_manipulation <folder> [options]
  raw_data_manipulation <folder> --run_type <type> [options]
  raw_data_manipulation <folder> --out <name> [options]
  raw_data_manipulation <folder> --nofadc [options]
  raw_data_manipulation <folder> --out <name> --nofadc [options]
  raw_data_manipulation -h | --help
  raw_data_manipulation --version

Options:
  --run_type <type>   Select run type (Calib | Data)
  --out <name>        Filename and path of output file
  --nofadc            Do not read FADC files
  -h --help           Show this help
  --version           Show version.

"""

template ch_len(): int = 2560
template all_ch_len(): int = ch_len() * 4

# macro combineBasename(typename: static[string]): typed =
#   # really ugly macro, mostly to toy around, to create basename templates
#   # creates a string, which is parsed to create templates, based on static
#   # string inputs
#   # returns a base string with for the given type, so that we
#   # can create names for the location of hardlinks for ToT, Hits etc
#   # for all runs
#   # set the name and beginning of returned string to be filled
#   let nim_template_name: string = """
# template combineBasename$#*(chip_number, run_number: int): string =
#   result: string = ""
#   let end_str = "_", chip_number, "_", run_number
#   result = "$#" & end_str
#   result""" % [typename, typename]
#   # add the further two fields to be handed to the function
#   #nim_template_name &= """$chip_number_$run_number"
#   #"""
#   result = parseStmt(nim_template_name)

# template combinedBasenameHits(chip_number, run_number: int) =
#   "Hits_$#_$#" % [$chip_number, $run_number]

template batchFiles(files: var seq[string], bufsize, actions: untyped): untyped =
  ## this is a template, which can be used to batch a set of files into chunks
  ## of size `bufsize`. This is done by deleting elements from `files` until it
  ## is empty. A block of code `actions` is given to the template, which will be
  ## performed.
  ## The variable ind_high is injected into the calling space, to allow the
  ## `actions` block to slice the current files
  ##
  ## Example:
  ##
  ## .. code-block:
  ##   let
  ##     fname_base = "data$#.txt"
  ##     files = mapIt(toSeq(0..<1000), fname_base & $it)
  ##   batch_files(files, 100):
  ##     # make use of batching for calc with high memory consumption, making use of
  ##     # injected `ind_high` variable
  ##     echo memoryConsumptuousCalc(files[0..ind_high])
  while len(files) > 0:
    # variable to set last index to read to
    var ind_high {.inject.} = bufsize
    if len(files) < bufsize:
      ind_high = len(files) - 1

    # perform actions as desired
    actions

    echo "... removing read elements from list"
    # sequtils.delete removes the element with ind_high as well!
    files.delete(0, ind_high)

proc batchFileReading[T](files: var seq[string],
                         regex_tup: tuple[header, chips, pixels: string] = ("", "", ""),
                         bufsize: int = FILE_BUFSIZE):
                          seq[FlowVar[ref T]] {.inline.} =
  # and removes all elements in the file list until all events have been read and the seq
  # is empty
  let
    t0 = epochTime()
    n_files = len(files)
  var count = 0
  # initialize sequence
  result = @[]

  batchFiles(files, bufsize):
    # read files into buffer sequence
    when T is Event:
      let buf_seq = readListOfInGridFiles(files[0..ind_high], regex_tup)
    elif T is FadcFile:
      let buf_seq = readListOfFadcFiles(files[0..ind_high])

    echo "... and concating buffered sequence to result"
    result = concat(result, buf_seq)
    count += bufsize
  echo "All files read. Number = " & $len(result)
  echo "Reading took $# seconds" % $(epochTime() - t0)
  echo "Compared with starting files " & $n_files


proc readRawInGridData(run_folder: string): seq[Event] =
  ## given a run_folder it reads all event files (data<number>.txt) and returns
  ## a sequence of Events, which store the raw event data
  ## Intermediately we receive FlowVars to ref Events after reading. We read via
  ## inodes, which may be scramled, so we sort the data and get the FlowVar values.
  ## NOTE: this procedure does the reading of the data in parallel, thanks to
  ## using spawn
  let regex_tup = getRegexForEvents()
  # get a sorted list of files, sorted by inode
  var files: seq[string] = getSortedListOfFiles(run_folder, EventSortType.inode, EventType.InGridType)
  let raw_ingrid = batchFileReading[Event](files, regex_tup)
  # now sort the seq of flowvars according to event numbers again, otherwise
  # h5 file is all mangled
  echo "Sorting data..."
  var numList = mapIt(raw_ingrid, (^it)[].evHeader["eventNumber"].parseInt)
  result = newSeq[Event](raw_ingrid.len)
  for i, ind in numList:
    result[ind] = (^raw_ingrid[i])[]
  echo "...Sorting done"
  
proc processRawInGridData(ch: seq[Event]): ProcessedRun = #seq[FlowVar[ref Event]]): ProcessedRun =
  ## procedure to process the raw data read from the event files by readRawInGridData
  ## inputs:
  ##    ch: seq[Event]] = seq of Event objects, which each store raw data of a single event.
  ##        We read normal events, perform calculations
  ##        to obtain ToT per pixel, number of hits and occupancies of that data
  ## outputs:
  ##   ProcessedRun containing:
  ##    events:    seq[Event] = the raw data from the seq of FlowVars saved in seq of Events
  ##    tuple of:
  ##      tot:  seq[seq[int]] = ToT values for each chip of Septemboard for run
  ##      hits: seq[seq[int]] = number of hits for each chip of Septemboard fo run
  ##      occ:    Tensor[int] = (7, 256, 256) tensor containing occupancies of all chips for
  ##        this data.

  # variable to count number of processed files
  var
    count = 0
    # store ToT data of all events for each chip
    # Note: still contains a single seq for each event! Need to concat
    # these seqs at the end
    tot_run: seq[seq[seq[int]]] = newSeq[seq[seq[int]]](7)
    # store occupancy frames for each chip
    occ = zeros[int](7, 256, 256)
    # store number of hits for each chip
    hits = newSeq[seq[int]](7)
    # initialize the events sequence of result, since we add to this sequence
    # instead of copying ch to it!
    events = newSeq[Event](len(ch))
  let
    # get the run specific time and shutter mode
    time = parseFloat(ch[0].evHeader["shutterTime"])
    mode = float(parseShutterMode(ch[0].evHeader["shutterMode"]))

  # set the run number
  result.run_number = parseInt(ch[0].evHeader["runNumber"])

  # initialize empty sequences. Input to anonymous function is var
  # as we change each inner sequence in place with newSeq
  apply(tot_run, (x: var seq[seq[int]]) => newSeq[seq[int]](x, len(ch)))
  apply(hits, (x: var seq[int]) => newSeq[int](x, len(ch)))

  echo "starting to process events..."
  count = 0
  for i in 0..ch.high:
  # assign the length field of the ref object
    # for the rest, get a copy of the event
    var a: Event = ch[i]
    # TODO: think about parallelizing here by having proc, which
    # works processes the single event?
    a.length = calcLength(a, time, mode)
    events[i] = a
    let chips = a.chips
    for c in chips:
      let
        num = c.chip.number
        pixels = c.pixels
      addPixelsToOccupancySeptem(occ, pixels, num)
      let tot_event = pixelsToTOT(pixels)
      tot_run[num][i] = tot_event
      let n_pix = len(tot_event)
      if n_pix > 0:
        # if the compiler flag (-d:CUT_ON_CENTER) is set, we cut all events, which are
        # in the center 4.5mm^2 square of the chip
        when defined(CUT_ON_CENTER):
          if isNearCenterOfChip(pixels) == true:
            hits[num][i] = n_pix
        else:
          hits[num][i] = n_pix
    echoFilesCounted(count)

  # using concatenation, flatten the seq[seq[int]] into a seq[int] for each chip
  # in the run (currently tot_run is a seq[seq[seq[int]]]. Convert to seq[seq[int]]
  let tot = map(tot_run, (t: seq[seq[int]]) -> seq[int] => concat(t))

  # use first event of run to fill event header. Fine, because event
  # header is contained in every file
  result.runHeader = fillRunHeader(ch[0]) #^ch[0])
  result.events = events
  result.tots = tot
  result.hits = hits
  result.occupancies = occ

{.experimental.}
proc processFadcData(fadc_files: seq[FlowVar[ref FadcFile]]): ProcessedFadcData {.inline.} =
  ## proc which performs all processing needed to be done on the raw FADC
  ## data. Starting from conversion of FadcFiles -> FadcData, but includes
  ## calculation of minimum and check for noisy events
  # sequence to store the indices needed to extract the 0 channel
  let
    fadc_ch0_indices = getCh0Indices()
    ch_len = ch_len()
    pedestal_run = getPedestalRun()
    nevents = fadc_files.len
    # we demand at least 4 dips, before we can consider an event as noisy
    n_dips = 4
    # the percentile considered for the calculation of the minimum
    min_percentile = 0.95

  # convert FlowVars of FadcFiles to sequence of FadcFiles
  result.raw_fadc_data = newSeq[seq[uint16]](nevents)
  result.fadc_data = zeros[float]([nevents, ch_len])
  result.trigrecs = newSeq[int](nevents)
  result.noisy = newSeq[int](nevents)
  result.minvals = newSeq[float](nevents)
  let t0 = epochTime()
  # TODO: parallelize this somehow so that it's faster!
  for i, event in fadc_files:
    let ev = (^event)[]
    result.raw_fadc_data[i] = ev.data
    result.trigrecs[i]      = ev.trigrec
    let fadc_dat = ev.fadcFileToFadcData(pedestal_run, fadc_ch0_indices).data
    result.fadc_data[i, _]  = fadc_dat.reshape([1, ch_len])
    result.noisy[i]         = fadc_dat.isFadcFileNoisy(n_dips)
    result.minvals[i]       = fadc_dat.calcMinOfPulse(min_percentile)

  # this parallel solution seems to be slower, instead of faster ?! well, probably
  # because we only have these two spawns and one of these functions is much slower
  # than the other
  # parallel:
  #   for i, event in fadc_files:
  #     let ev = (^event)[]
  #     if i < result.raw_fadc_data.len:
  #       result.raw_fadc_data[i] = ev.data
  #     let fadc_dat = ev.fadcFileToFadcData(pedestal_run, fadc_ch0_indices).data
  #     if i < result.trigrecs.len:
  #       result.trigrecs[i]      = ev.trigrec
  #       result.fadc_data[i, _]  = fadc_dat.reshape([1, ch_len])
  #     if i < result.noisy.len:
  #       result.noisy[i]         = spawn fadc_dat.isFadcFileNoisy(n_dips)
  #     if i < result.minvals.len:
  #       result.minvals[i]       = spawn fadc_dat.calcMinOfPulse(min_percentile)
  #     sync()
  echo "Calculation of $# events took $# seconds" % [$nevents, $(epochTime() - t0)]

proc initFadcInH5(h5f: var H5FileObj, run_number, batchsize: int, filename: string) =
  # proc to initialize the datasets etc in the HDF5 file for the FADC. Useful
  # since we don't want to do this every time we call the write function
  let
    ch_len = ch_len()
    all_ch_len = all_ch_len()

  let
    group_name = getGroupNameForRun(run_number) & "/fadc"
    reco_group_name = getRecoNameForRun(run_number) & "/fadc"
  var
    # create the groups for the run and reconstruction data
    run_group = h5f.create_group(group_name)
    reco_group = h5f.create_group(reco_group_name)
    fadc_combine = h5f.create_group(combineRecoBasenameFadc)
    # create the datasets for raw data etc
    # NOTE: we initialize all datasets with a size of 0. This means we need to extend
    # it immediately. However, this allows us to always (!) simply extend and write
    # the data to dset.len onwards!
    raw_fadc_dset = h5f.create_dataset(rawFadcBasename(run_number), (0, all_ch_len),
                                       uint16,
                                       chunksize = @[batchsize, all_ch_len],
                                       maxshape = @[int.high, all_ch_len])
    fadc_dset     = h5f.create_dataset(fadcDataBasename(run_number), (0, ch_len),
                                       float,
                                       chunksize = @[batchsize, ch_len],
                                       maxshape = @[int.high, ch_len])
    trigrec_dset  = h5f.create_dataset(trigrecBasename(run_number), (0, 1),
                                       int,
                                       chunksize = @[batchsize, 1],
                                       maxshape = @[int.high, 1])
    # dataset stores flag whether FADC event was a noisy one (using our algorithm)
    noisy_dset    = h5f.create_dataset(noiseBasename(run_number), (0, 1),
                                       int,
                                       chunksize = @[batchsize, 1],
                                       maxshape = @[int.high, 1])
    # dataset stores minima of each FADC event, dip voltage
    minvals_dset  = h5f.create_dataset(minvalsBasename(run_number), (0, 1),
                                       float,
                                       chunksize = @[batchsize, 1],
                                       maxshape = @[int.high, 1])

  # write attributes to FADC groups
  # read the given FADC file and extract that information from it
  let fadc_for_attrs = readFadcFile(filename)
  # helper sequence to loop over both groups to write attrs
  var group_seq = @[run_group, reco_group]
  for group in mitems(group_seq):
    group.attrs["posttrig"] = fadc_for_attrs.posttrig
    group.attrs["pretrig"] = fadc_for_attrs.pretrig
    group.attrs["n_channels"] = fadc_for_attrs.n_channels
    group.attrs["channel_mask"] = fadc_for_attrs.channel_mask
    group.attrs["frequency"] = fadc_for_attrs.frequency
    group.attrs["sampling_mode"] = fadc_for_attrs.sampling_mode
    group.attrs["pedestal_run"] = if fadc_for_attrs.pedestal_run == true: 1 else: 0

proc writeFadcDataToH5(h5f: var H5FileObj, run_number: int, f_proc: ProcessedFadcData) =
  # proc to write the current FADC data to the H5 file
  # now write the data
  let
    reco_group_name = getRecoNameForRun(run_number)
    raw_name = rawFadcBasename(run_number)
    reco_name = fadcDataBasename(run_number)
    trigrec_name = trigrecBasename(run_number)
    ch_len = ch_len()
    all_ch_len = all_ch_len()
    nevents = f_proc.raw_fadc_data.len
  var
    raw_fadc_dset = h5f[raw_name.dset_str]
    fadc_dset = h5f[reco_name.dset_str]
    trigrec_dset = h5f[trigrec_name.dset_str]
    noisy_dset = h5f[noiseBasename(run_number).dset_str]
    minvals_dset = h5f[minvalsBasename(run_number).dset_str]

  echo raw_fadc_dset.shape
  echo raw_fadc_dset.maxshape
  echo fadc_dset.shape
  echo fadc_dset.maxshape
  echo trigrec_dset.shape
  echo trigrec_dset.maxshape
  # first need to extend the dataset, as we start with a size of 0.
  let oldsize = raw_fadc_dset.shape[0]
  let newsize = oldsize + nevents
  # TODO: currently this is somewhat problematic. We simply resize always. In a way this is
  # fine, because we need to resize to append. But in case we start this program twice in
  # a row, without deleting the file, we simply extend the dataset further, because we read
  # the current (final!) shape from the file
  # NOTE: one way to mitigate t his, would be to set oldsize as a {.global.} variable
  # in which case we simply set it to 0 on the first call and afterwards extend it by
  # the size we add
  raw_fadc_dset.resize((newsize, all_ch_len))
  fadc_dset.resize((newsize, ch_len))
  trigrec_dset.resize((newsize, 1))
  noisy_dset.resize((newsize, 1))
  minvals_dset.resize((newsize, 1))

  # now write the data
  let t0 = epochTime()
  # TODO: speed this up
  # write using hyperslab
  echo "Trying to write using hyperslab! from $# to $#" % [$oldsize, $newsize]
  raw_fadc_dset.write_hyperslab(f_proc.raw_fadc_data,
                                offset = @[oldsize, 0],
                                count = @[nevents, all_ch_len])
  fadc_dset.write_hyperslab(f_proc.fadc_data.toRawSeq,
                            offset = @[oldsize, 0],
                            count = @[nevents, ch_len])
  trigrec_dset.write_hyperslab(f_proc.trigrecs,
                               offset = @[oldsize, 0],
                               count = @[nevents, 1])
  noisy_dset.write_hyperslab(f_proc.noisy,
                             offset = @[oldsize, 0],
                             count = @[nevents, 1])
  minvals_dset.write_hyperslab(f_proc.minvals,
                               offset = @[oldsize, 0],
                               count = @[nevents, 1])
  echo "Writing of FADC data took $# seconds" % $(epochTime() - t0)

proc finishFadcWriteToH5(h5f: var H5FileObj, run_number: int) =
  # proc to finalize the last things we need to write for the FADC data
  # for now only hardlinking to combine group
  let
    noisy_target = noiseBasename(run_number)
    minvals_target = minvalsBasename(run_number)
    noisy_link = combineRecoBasenameNoisy(run_number)
    minvals_link = combineRecoBasenameMinvals(run_number)

  h5f.create_hardlink(noisy_target, noisy_link)
  h5f.create_hardlink(minvals_target, minvals_link)

proc readProcessWriteFadcData(run_folder: string, run_number: int, h5f: var H5FileObj) =
  ## given a run_folder it reads all fadc files (data<number>.txt-fadc),
  ## processes it (FadcFile -> FadcData) and writes it to the HDF5 file

  # get a sorted list of files, sorted by inode
  var
    files: seq[string] = getSortedListOfFiles(run_folder, EventSortType.fname, EventType.FadcType)
    raw_fadc_data: seq[FlowVar[ref FadcFile]] = @[]
    # variable to store the processed FADC data
    f_proc: ProcessedFadcData
    # in case of FADC data we cannot afford to read all files into memory before
    # writing some to HDF5, because the memory overhead from storing all files
    # in seq[string] is too large (17000 FADC files -> 10GB needed!)
    # thus already perform batching here
    files_read: seq[string] = @[]
  # use batchFiles template to work on 1000 files per batch

  const batchsize = 1000

  # before we start iterating over the files, initialize the H5 file
  h5f.initFadcInH5(run_number, batchsize, files[0])

  batchFiles(files, batchsize - 1):
    # batch in 1000 file pieces
    var mfiles = files[0..ind_high]
    echo "Starting with file $# and ending with file $#" % [$mfiles[0], $mfiles[^1]]
    files_read = files_read.concat(mfiles)

    raw_fadc_data = batchFileReading[FadcFile](mfiles)

    # TODO: read FADC files also by inode and then sort the fadc 
    # we just read here. NOTE: for that have to change the writeFadcDataToH5
    # proc to accomodate that!
    
    # given read files, we now need to append this data to the HDF5 file, before
    # we can process more data, otherwise we might run out of RAM
    f_proc = raw_fadc_data.processFadcData
    echo "Number of FADC files in this batch ", raw_fadc_data.len

    h5f.writeFadcDataToH5(run_number, f_proc)

  echo files_read.toSet.len
  # finally finish writing to the HDF5 file
  finishFadcWriteToH5(h5f, run_number)

proc writeProcessedRunToH5(h5f: var H5FileObj, run: ProcessedRun) =
  # this procedure writes the data from the processed run to a HDF5
  # (opened already) given by h5file_id
  # inputs:
  #   h5f: H5file = the H5 file object of the writeable HDF5 file
  #   run: ProcessedRun = a tuple of the processed run data
  const nchips = 7
  let nevents = run.events.len
  let run_number = run.run_number
  # start by creating groups

  # TODO: write the run information into the meta data of the group
  echo "Create data to write to HDF5 file"
  let t0 = epochTime()
  # first write the raw data
  let
    # group name for raw data
    group_name = getGroupNameForRun(run_number)
    # group name for reconstructed data
    reco_group_name = getRecoNameForRun(run_number)

    ev_type_xy = special_type(uint8)
    ev_type_ch = special_type(uint16)
    chip_group_name = group_name & "/chip_$#" #% $chp
    combine_group_name = getRawCombineName()
    event_header_keys = ["eventNumber", "useHvFadc", "fadcReadout", "timestamp",
                         "szint1ClockInt", "szint2ClockInt", "fadcTriggerClock"]
  var
    # group for raw data
    run_group = h5f.create_group(group_name)
    # group for reconstructed data
    reco_group = h5f.create_group(reco_group_name)
    # combined data group
    combine_group = h5f.create_group(combine_group_name)

    # create group for each chip
    chip_groups = mapIt(toSeq(0..<nchips), h5f.create_group(chip_group_name % $it))
    x_dsets  = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_x", nevents, dtype = ev_type_xy))
    y_dsets  = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_y", nevents, dtype = ev_type_xy))
    ch_dsets = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_ch", nevents, dtype = ev_type_ch))

    # datasets to store the header information for each event
    evHeadersDsetTab = (mapIt(event_header_keys) do:
      (it, h5f.create_dataset(group_name & "/" & it, nevents, dtype = int))).toTable
    # TODO: add string of datetime as well
    #dateTimeDset = h5f.create_dataset(joinPath(group_name, "dateTime"), nevents, string)

    # other single column data
    durationDset = h5f.create_dataset(joinPath(group_name, "eventDuration"), nevents, float)
    duration = newSeq[float](nevents)

    evHeaders = initTable[string, seq[int]]()
    x  = newSeq[seq[seq[uint8]]](nchips)
    y  = newSeq[seq[seq[uint8]]](nchips)
    ch = newSeq[seq[seq[uint16]]](nchips)

  # prepare event header keys and value (init seqs)
  for key in event_header_keys:
    evHeaders[key] = newSeq[int](nevents)

  for i in 0..6:
    x[i]  = newSeq[seq[uint8]](nevents)
    y[i]  = newSeq[seq[uint8]](nevents)
    ch[i] = newSeq[seq[uint16]](nevents)
  for event in run.events:
    # given chip number, we can write the data of this event to the correct dataset
    let evNumber = parseInt(event.evHeader["eventNumber"])
    duration[evNumber] = event.length
    # add event header information
    for key in keys(evHeaders):
      try:
        evHeaders[key][evNumber] = parseInt(event.evHeader[key])
      except KeyError:
        echo "We're reading event $# with evHeaders" % [$event] #, $evHeaders]
        raise
    # add raw chip pixel information
    for chp in event.chips:
      let
        num = chp.chip.number
      let hits = chp.pixels.len
      var
        xl: seq[uint8] = newSeq[uint8](hits)
        yl: seq[uint8] = newSeq[uint8](hits)
        chl: seq[uint16] = newSeq[uint16](hits)
      for i, p in chp.pixels:
        xl[i] = uint8(p[0])
        yl[i] = uint8(p[1])
        chl[i] = uint16(p[2])
      x[num][evNumber] = xl
      y[num][evNumber] = yl
      ch[num][evNumber] = chl

  echo "Writing all dset x data "
  let all = x_dsets[0].all
  for i in 0..x_dsets.high:
    echo "Writing dsets"
    x_dsets[i][all]  = x[i]
    y_dsets[i][all]  = y[i]
    ch_dsets[i][all] = ch[i]
  for key, dset in mpairs(evHeadersDsetTab):
    echo "Writing $# in $#" % [$key, $dset]
    dset[dset.all] = evHeaders[key]

  # write other single column datasets
  durationDset[durationDset.all] = duration
  # link over to reconstruction group
  h5f.create_hardlink(durationDset.name, reco_group_name / extractFilename(durationDset.name))
  echo "took a total of $# seconds" % $(epochTime() - t0)

  ####################
  #  Reconstruction  #
  ####################

  # create hard links of header data to reco group
  for key, dset in mpairs(evHeadersDsetTab):
    echo "Writing $# in $#" % [$key, $dset]
    h5f.create_hardlink(dset.name, joinPath(reco_group_name, key))

  # now write attribute data (containing the event run header, for a start
  # NOTE: unfortunately we cannot write all of it simply using applyIt,
  # because we need to parse some numbers as ints, leave some as strings
  let asInt = ["runNumber", "runTime", "runTimeFrames", "numChips", "shutterTime",
               "runMode", "fastClock", "externalTrigger"]
  let asString = ["pathName", "dateTime", "shutterMode"]
  # write run header
  for it in asInt:
    run_group.attrs[it]  = parseInt(run.runHeader[it])
    reco_group.attrs[it] = parseInt(run.runHeader[it])
  for it in asString:
    run_group.attrs[it] = run.runHeader[it]
    reco_group.attrs[it] = run.runHeader[it]

  # write attributes for each chip
  var i = 0
  for grp in mitems(chip_groups):
    grp.attrs["chipNumber"] = run.events[0].chips[i].chip.number
    grp.attrs["chipName"]   = run.events[0].chips[i].chip.name
    inc i

  echo "ToTs shape is ", run.tots.shape
  echo "hits shape is ", run.hits.shape
  # into the reco group name we now write the ToT and Hits information
  # var tot_dset = h5f.create_dataset(reco_group & "/ToT")
  for chip in 0..run.tots.high:
    # since not every chip has hits on each event, we need to create one group
    # for each chip and store each chip's data in these

    #let chip_group_name = reco_group_name & "/chip_$#" % $chip
    #var chip_group = h5f.create_group(chip_group_name)

    # write chip name and number, taken from first event
    chip_groups[chip].attrs["chipNumber"] = run.events[0].chips[chip].chip.number
    chip_groups[chip].attrs["chipName"]   = run.events[0].chips[chip].chip.name
    # in this chip group store:
    # - occupancy
    # - ToTs
    # - Hits
    # ... more later
    let
      tot = run.tots[chip]
      hit = run.hits[chip]
      occ = run.occupancies[chip, _, _].clone
    var
      tot_dset = h5f.create_dataset((chip_group_name % $chip) & "/ToT", tot.len, int)
      hit_dset = h5f.create_dataset((chip_group_name % $chip) & "/Hits", hit.len, int)
      occ_dset = h5f.create_dataset((chip_group_name % $chip) & "/Occupancy", (256, 256), int)
    tot_dset[tot_dset.all] = tot
    hit_dset[hit_dset.all] = hit
    occ_dset[occ_dset.all] = occ

    # create hardlinks for ToT and Hits
    h5f.create_hardlink(tot_dset.name, combineRawBasenameToT(chip, run_number))
    h5f.create_hardlink(hit_dset.name, combineRawBasenameHits(chip, run_number))

proc processSingleRun(run_folder: string, h5f: var H5FileObj, nofadc = false): ProcessedRun =
  ## this procedure performs the necessary manipulations of a single
  ## run. This is the main part of the raw data manipulation
  ## inputs:
  ##     run_folder: string = the run folder (has to be one!, check with isTosRunFolder())
  ##         to be processed
  ##     h5f: var H5FileObj = mutable copy of the H5 file object to which we will write
  ##         the data
  ##     nofadc: bool = if set, we do not read FADC data

  # need to:
  # - create list of all data<number>.txt files in the folder
  #   - and corresponding -fadc files
  # - read event header for each file
  # -
  # read the raw event data into a seq of FlowVars
  let ingrid = readRawInGridData(run_folder)
  # process the data read into seq of FlowVars, save as result
  result = processRawInGridData(ingrid)

  # for the FADC we call a single function here, which works on
  # the FADC files in a buffered way, always reading 1000 FADC
  # filsa at a time.
  let mem1 = getOccupiedMem()
  echo "occupied memory before fadc $# \n\n" % [$mem1]
  if nofadc == false:
    readProcessWriteFadcData(run_folder, result.run_number, h5f)
    echo "FADC took $# data" % $(getOccupiedMem() - mem1)

proc processAndWriteRun(h5f: var H5FileObj, run_folder: string, nofadc = false) =
  ## proc to process and write a single run
  ## inputs:
  ##     h5f: var H5FileObj = mutable copy of the H5 file object to which we will write
  ##         the data
  ##     nofadc: bool = if set, we do not read FADC data
  let r = processSingleRun(run_folder, h5f, nofadc)
  let a = squeeze(r.occupancies[2,_,_])
  dumpFrameToFile("tmp/frame.txt", a)
  writeProcessedRunToH5(h5f, r)

  echo "Size of total ProcessedRun object = ", sizeof(r)
  echo "Length of tots and hits for each chip"
  # dump sequences to file
  #dumpToTandHits(folder, run_type, r.tots, r.hits)

proc main() =

  # use the usage docstring to generate an CL argument table
  let args = docopt(doc)
  echo args

  let folder = $args["<folder>"]
  var run_type = $args["--run_type"]
  var outfile = $args["--out"]
  if run_type == "nil":
    run_type = ""
  if outfile == "nil":
    outfile = "run_file.h5"
  var nofadc: bool = false
  if $args["--nofadc"] != "false":
    echo $args["--nofadc"]
    nofadc = true

  echo &"No fadc is {nofadc}"

  # first check whether given folder is valid run folder
  let (is_run_folder, contains_run_folder) = isTosRunFolder(folder)
  echo "Is run folder       : ", is_run_folder
  echo "Contains run folder : ", contains_run_folder

  # in order to write the processed run and FADC data to file, open the HDF5 file
  var h5f = H5file(outfile, "rw")

  let t0 = epochTime()
  if is_run_folder == true and contains_run_folder == false:
    # hand H5FileObj to processSingleRun, because we need to write intermediate
    # steps to the H5 file for the FADC, otherwise we use too much RAM
    processAndWriteRun(h5f, folder, nofadc)
    echo "free memory ", getFreeMem()
    echo "occupied memory so far $# \n\n" % [$getOccupiedMem()]
    echo "Closing h5file with code ", h5f.close()
  elif is_run_folder == false and contains_run_folder == true:
    # in this case loop over all folder again and call processSingleRun() for each
    # run folder
    for kind, path in walkDir(folder):
      if kind == pcDir:
        # only support run folders, not nested run folders
        echo "occupied memory before run $# \n\n" % [$getOccupiedMem()]
        let
          is_rf = if isTosRunFolder(path) == (true, false): true else: false
        if is_rf == true:
          echo "Start processing run $#" % $path
          processAndWriteRun(h5f, path, nofadc)
        echo "occupied memory after gc $#" % [$getOccupiedMem()]
    echo "Closing h5file with code ", h5f.close()
  elif is_run_folder == true and contains_run_folder == true:
    echo "Currently not implemented to run over nested run folders."
    quit()
  else:
    echo "No run folder found in given path."
    quit()

  echo "Processing all given runs took $# minutes" % $( (epochTime() - t0) / 60'f )

when isMainModule:
  main()





# alternative approach writing each event one after another.
# however, this is about 9 times slower...
# let
#   ev_type = special_type(int)
#   chip_group_name = group_name & "/chip_$#" #% $chp
#   # create group for each chip
#   chip_groups = mapIt(toSeq(0..<nchips), h5f.create_group(chip_group_name % $it))
# var
#   x_dsets  = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_x", nevents, dtype = ev_type))
#   y_dsets  = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_y", nevents, dtype = ev_type))
#   ch_dsets = mapIt(chip_groups, h5f.create_dataset(it.name & "/raw_ch", nevents, dtype = ev_type))
# for event in run.events:
#   for chp in event.chips:
#     let
#       num = chp.chip.number
#     # given chip number, we can write the data of this event to the correct dataset
#     let evNumber = parseInt(event.evHeader["eventNumber"])
#     let hits = chp.pixels.len
#     var
#       xl: seq[int] = newSeq[int](hits)
#       yl: seq[int] = newSeq[int](hits)
#       chl: seq[int] = newSeq[int](hits)
#     for i, p in chp.pixels:
#       xl[i] = p[0]
#       yl[i] = p[1]
#       chl[i] = p[2]
#     x_dsets[num].write(@[@[evNumber, 0]], xl)
#     y_dsets[num].write(@[@[evNumber, 0]], yl)
#     ch_dsets[num].write(@[@[evNumber, 0]], chl)