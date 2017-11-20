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

# InGrid-module
import helper_functions
import tos_helper_functions

# other modules  
import nimhdf5/H5nimtypes
import arraymancer

# global experimental pragma to use parallel: statement in readRawEventData()
{.experimental.}

proc readRawEventData(run_folder: string): seq[FlowVar[ref Event]] =
  # given a run_folder it reads all event files (data<number>.txt) and returns
  # a sequence of FlowVars of references to Events, which store the raw
  # event data
  # NOTE: this procedure does the reading of the data in parallel, thanks to
  # using spawn
  
  let
    event_regex = r".*data\d{4,6}\.txt$"
  # get the list of files from this run folder and sort it
    f = sorted(getListOfFiles(run_folder, event_regex),
                 (x: string, y: string) -> int => system.cmp[string](x, y))
    #let f = getListOfFiles(run_folder, event_regex)
    regex_tup = getRegexForEvents()
    t0 = cpuTime()     
  var count = 0
  result = newSeq[FlowVar[ref Event]](len(f))

  parallel:
    for i, el in f:
      if i > 10000:
        break
      if i <= result.high:
        result[i] = spawn readEventWithRegex(el, regex_tup)
      inc count
      if count mod 500 == 0:
        echo count, " files read."
  let t1 = cpuTime()
  echo "reading of files took: ", t1 - t0
  sync()

proc processRawEventData(ch: seq[FlowVar[ref Event]]): ProcessedRun =
  # procedure to process the raw data read from the event files by readRawEventData
  # inputs:
  #    ch: seq[FlowVar[ref Event]] = seq of FlowVars of references to Event objects, which
  #        each store raw data of a single event.
  #        We read data of FlowVars and store it in normal events, perform calculations
  #        to obtain ToT per pixel, number of hits and occupancies of that data
  # outputs:
  #   ProcessedRun containing:
  #    events: seq[Event] = the raw data from the seq of FlowVars saved in seq of Events
  #    tuple of:
  #      tot: seq[seq[int]] = ToT values for each chip of Septemboard for run
  #      hits: seq[seq[int]] = number of hits for each chip of Septemboard fo run
  #      occ: Tensor[int] = (7, 256, 256) tensor containing occupancies of all chips for
  #        this data.

  # variable to count number of processed files
  var
    count = 0
    # store ToT data of all events for each chip
    # Note: still contains a single seq for each event! Need to concat
    # these seqs at the end
    tot_run: seq[seq[seq[int]]] = newSeq[seq[seq[int]]](7)
    # store occupancy frames for each chip
    #occ = zeros[int](7, 256, 256)
    occ: seq[Tensor[int]] = newSeq[Tensor[int]](7)
    # store number of hits for each chip
    hits = newSeq[seq[int]](7)
    # initialize the events sequence of result, since we add to this sequence
    # instead of copying ch to it!
    events = newSeq[Event](len(ch))

  # initialize empty sequences. Input to anonymous function is var
  # as we change each inner sequence in place with newSeq
  apply(tot_run, (x: var seq[seq[int]]) => newSeq[seq[int]](x, 0))
  apply(hits, (x: var seq[int]) => newSeq[int](x, 0))
  #map(occ, (x: var Tensor[int]) => zeros[int](256, 256))
  for i in 0..<occ.high:
    occ[i] = zeros[int](256, 256)

  proc processChip(c: ChipEvent, o: var Tensor[int], tot: var seq[seq[int]], hit: var seq[int]) =
    echo "1"
    let pixels = c.pixels
    echo "2"
    addPixelsToOccupancy(o, pixels)
    echo "3"
    let tot_event = pixelsToTOT(pixels)
    echo "4"
    tot.add(tot_event)
    echo "5"
    let n_pix = len(tot_event)
    echo "6"
    if n_pix > 0:
      hit.add(n_pix)
    echo "7"
    
  count = 0
  for i in 0..<10000:
    let a: Event = (^ch[i])[]
    events.add(a)
    let chips = a.chips
    #let chip3 = filter(chips) do (ch: ChipEvent) -> bool : ch.chip.number == 3
    parallel:
      for c in chips:
        let num = c.chip.number
        if num < occ.high:
          if num < tot_run.len:
            if num < hits.len:
              spawn processChip(c, occ[num], tot_run[num], hits[num])
        # let pixels = c.pixels
        # addPixelsToOccupancySeptem(occ, pixels, num)
        # let tot_event = pixelsToTOT(pixels)
        # if num < len(tot_run):
        #   tot_run[num].add(^tot_event)
        # let n_pix = len(^tot_event)
        # if n_pix > 0:
        #   if num < hits.high:
        #     hits[num].add(n_pix)
    sync()
    sleep(100)
    echoFilesCounted(count)
    #echo n_pix

  # using concatenation, flatten the seq[seq[int]] into a seq[int] for each chip
  # in the run (currently tot_run is a seq[seq[seq[int]]]. Convert to seq[seq[int]]
  let tot = map(tot_run, (t: seq[seq[int]]) -> seq[int] => concat(t))

  # the data we have now represents our needed processed data for each run
  # (excluding FADC)
  # events: the raw event data (header plus hits)
  # tot_run: for each chip seq of ToT values (excl 11810) to create
  #   ToT per pixel histogram for each chip
  # occupancies: for each chip tensor of ints containing number of hits of
  #   each pixel for whole run
  # hits: for each chip seq of number of hits (excl 11810 hits) to create
  #   Hits per event for whole run (e.g. energy calibration)
  result.events = events
  result.tots = tot
  result.hits = hits
  result.occupancies = occ

proc processSingleRun(run_folder: string, h5file_id: hid_t): ProcessedRun =
  # this procedure performs the necessary manipulations of a single
  # run. This is the main part of the raw data manipulation
  # inputs:
  #     run_folder: string = the run folder (has to be one!, check with isTosRunFolder())
  #         to be processed
  #     h5file_id: hid_t   = the file id of the HDF5 file, to which we write the data

  # need to:
  # - create list of all data<number>.txt files in the folder
  #   - and corresponding -fadc files
  # - read event header for each file
  # -
  
  # read the raw event data into a seq of FlowVars
  let ch = readRawEventData(run_folder)

  # process the data read into seq of FlowVars, save as result
  result = processRawEventData(ch)

proc isTosRunFolder(folder: string): tuple[is_rf: bool, contains_rf: bool] =
  # this procedure checks whether the given folder is a valid run folder of
  # TOS
  # done by
  # - checking whether the name of the folder is a valid name for a
  #   run folder (contains Run_<number>) in the name and 
  # - checking whether folder contains data<number>.txt files
  # inputs:
  #    folder: string = the given name of the folder to check
  # outputs:
  # returns a tuple which not only says whether it is a run folder, but also
  # whether the folder itself contains a run folder
  #    tuple[bool, bool]:
  #        is_rf:       is a run folder
  #        contains_rf: contains run folders
  let run_regex = r".*Run_(\d+)_.*"
  let event_regex = r".*data\d{4,6}\.txt$"
  var matches_rf_name: bool = false
  if match(folder, re(run_regex)) == true:
    # set matches run folder flag to true, is checked when we find
    # a data<number>.txt file in the folder, so that we do not think a
    # folder with a single data<number>.txt file is a run folder
    matches_rf_name = true
    
  for kind, path in walkDir(folder):
    if kind == pcFile:
      if match(path, re(event_regex)) == true and matches_rf_name == true:
        result.is_rf = true
        # in case we found an event in the folder, we might want to stop the
        # search, in order not to waste time. Nested run folders are
        # undesireable anyways
        # for now we leave this comment here, since it may come in handy
        # break
    else:
      # else we deal with a folder. call this function recuresively
      let (is_rf, contains_rf) = isTosRunFolder(path)
      # if the underlying folder contains an event file, this folder thus
      # contains a run folder
      if is_rf == true:
        result.contains_rf = true
  
proc main() = 

  let args_count = paramCount()
  var folder: string
  if args_count < 1:
    echo "Please either hand a single run folder or a folder containing run folder, which to process."
    quit()
  else:
    folder = paramStr(1)
    
  # first check whether given folder is valid run folder
  let (is_run_folder, contains_run_folder) = isTosRunFolder(folder)
  echo "Is run folder       : ", is_run_folder
  echo "Contains run folder : ", contains_run_folder

  var h5file_id: hid_t = 0
  
  # if we're dealing with a run folder, go straight to processSingleRun()
  if is_run_folder == true and contains_run_folder == false:
    let r = processSingleRun(folder, h5file_id)
    for l in r.tots:
      echo l.len
    for l in r.hits:
      echo l
    
  elif is_run_folder == false and contains_run_folder == true:
    # in this case loop over all folder again and call processSingleRun() for each
    # run folder
    for kind, path in walkDir(folder):
      if kind == pcDir:
        # only support run folders, not nested run folders
        let is_rf = if isTosRunFolder(path) == (true, false): true else: false
        let r = processSingleRun(path, h5file_id)
  elif is_run_folder == true and contains_run_folder == true:
    echo "Currently not implemented to run over nested run folders."
    quit()
  else:
    echo "No run folder found in given path."
    quit()

when isMainModule:
  main()