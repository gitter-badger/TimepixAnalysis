import os
import docopt
import arraymancer
import re
import strutils, strformat, sequtils
import ingrid/tos_helpers
import helpers/utils
import zero_functional
import seqmath
import nimhdf5
import times

import ingrid/ingrid_types
import ingrid/calibration

const doc = """
The InGrid database management tool.

Usage:
  ingridDatabase (--add=FOLDER | --calibrate=TYPE | --modify | --delete=CHIPNAME) [options]

Options:
  --add=FOLDER        Add the chip contained in the given FOLDER 
                      to the database
  --calibrate=TYPE    Perform given calibration (TOT / SCurve) and save
                      fit parameters as attributes. Calibrates all chips
                      with suitable data.                      
  --modify            start a CLI interface to allow viewing the files
                      content and modify attributes / delete elements
  --delete=CHIPNAME   Delete contents of CHIPNAME from database
  -h, --help          Show this help
  --version           Show the version number

Documentation:
  This tool and library aims to provide two things. Running it as a main 
  module, it is a tool to add / manage the InGrid database HDF5 file, which
  stores information like FSR, thresholds, TOT calibration etc. for each chip
  with the corresponding name and location (e.g. Septem H).
  As a library it provides convenience functions to access the database to
  read and write to it, e.g.
  getTot(chipName)
  to get the ToT values of that chip.
"""

type
  ChipName* = object
    col*: char
    row*: int
    wafer*: int
    
  Chip* = object
    name*: ChipName
    info*: Table[string, string]

  TotType* = object
    pulses*: int
    mean*: float
    std*: float

  TypeCalibrate* {.pure.} = enum
    TotCalibrate = "tot"
    SCurveCalibrate = "scurve"

# helper proc to remove the ``src`` which is part of `nimble path`s output
# this is a bug, fix it.
proc removeSuffix(s: string, rm: string): string {.compileTime.} =
  result = s
  result.removeSuffix(rm)
    
const ingridPath = staticExec("nimble path ingridDatabase").removeSuffix("src")
const db = "resources/ingridDatabase.h5"
const dbPath = joinPath(ingridPath, db)

const
  ChipInfo = "chipInfo.txt"
  FsrPrefix = "fsr"
  FsrPattern = "fsr*.txt"
  TotPrefix = "TOTCalib"
  TotPattern = TotPrefix & r"*\.txt"
  ThresholdPrefix = "threshold"
  ThresholdPattern = r"threshold[0-9]\.txt"
  ThresholdMeansPrefix = ThresholdPrefix & "Means"
  ThresholdMeansPattern = ThresholdPrefix & r"Means*\.txt"
  SCurvePrefix = "voltage_"
  SCurveRegPrefix = r".*" & SCurvePrefix
  SCurvePattern = r"voltage_*\.txt"
  SCurveFolder = "SCurve/"
  StartTotRead = 20.0
let
  ChipNameLineReg = re(r"chipName:")
  ChipNameReg = re(r".*([A-Z])\s*([0-9]+)\s*W\s*([0-9]{2}).*")
  FsrReg = re(FsrPrefix & r"([0-9])\.txt")
  FsrContentReg = re(r"(\w+)\s([0-9]+)")
  TotReg = re(TotPrefix & r"([0-9])\.txt")
  SCurveReg = re(SCurveRegPrefix & r"([0-9]+)\.txt")

template withDatabase(actions: untyped): untyped =
  ## read only template to open database as `hf5`, work with it
  ## and close it properly
  ## NOTE: The database is only opened, if no other variable
  ## of the name `h5f` is declared in the calling scope.
  ## This allows to have nested calls of `withDebug` without
  ## any issues (otherwise we get will end up trying to close
  ## already closed objects)
  when not declaredInScope(h5f):
    echo "Opening db at ", dbPath
    var h5f {.inject.} = H5File(dbPath, "r")
  actions
  when not declaredInScope(h5f):
    let err = h5f.close()
    if err < 0:
      echo "Could not properly close database! err = ", err

proc `$`(chip: ChipName): string =
  result = $chip.col & $chip.row & " W" & $chip.wafer

proc parseChipName(chipName: string): ChipName =
  ## parses the given `chipName` as a string to a `ChipName` object
  var mChip: array[3, string]
  # parse the chip name
  if match(chipName, ChipNameReg, mChip) == true:
    result.col   = mChip[0][0]
    result.row   = mChip[1].parseInt
    result.wafer = mChip[2].parseInt
  else:
    raise newException(ValueError, "Bad chip name: $#" % chipName)

proc chipNameToGroup(chipName: string): string =
  ## given a `chipName` will return the correct name of the corresponding
  ## chip's group
  ## done by parsing the given string to a `ChipName` and using `ChipNames`
  ## `$` proc.
  result = $(parseChipName(chipName))

# procs to get data from the file
proc getTotCalib*(chipName: string): Tot =
  ## reads the TOT calibration data from the database for `chipName`
  let dsetName = joinPath(chipNameToGroup(chipName), TotPrefix)
  withDatabase:
    var dset = h5f[dsetName.dset_str]
    let data = dset[float64].reshape2D(dset.shape).transpose
    result.pulses = data[0].asType(int)
    result.mean = data[1]
    result.std = data[2]

proc getScurve*[T: SomeInteger](h5f: var H5FileObj,
                                chipName: string,
                                voltage: T):
                                  SCurve =
  ## reads the given voltages' SCurve for `chipName`
  result.name = SCurvePrefix & $voltage
  let dsetName = joinPath(joinPath(chipNameToGroup(chipName),
                                   SCurveFolder),
                          result.name)
  result.voltage = voltage
  var dset = h5f[dsetName.dset_str]
  let data = dset[int64].reshape2D(dset.shape).transpose
  result.thl = data[0].asType(int)
  result.hits = data[1].asType(int)

proc getScurve*(chipName: string, voltage: int): SCurve =
  ## reads the given voltages' SCurve for `chipName`
  ## overload of above for the case of non opened H5 file
  withDatabase:
    result = h5f.getScurve(chipName, voltage)
    
proc getScurveSeq*(chipName: string): SCurveSeq =
  ## read all SCurves of `chipName` and return an `SCurveSeq`
  # init result seqs (for some reason necessary?!)
  result.files = @[]
  result.curves = @[]
  var groupName = joinPath(chipNameToGroup(chipName),
                           SCurveFolder)
  echo "done ", groupName
  withDatabase:
    h5f.visitFile()
    groupName = joinPath(chipNameToGroup(chipName),
                         SCurveFolder)
    var grp = h5f[groupName.grp_str]
    for dset in grp:
      var mdset = dset
      let voltage = mdset.attrs["voltage", int64].int
      let curve = h5f.getSCurve(chipName, voltage)
      result.files.add dset.name
      result.curves.add curve

proc getThreshold*(chipName: string): Threshold =
  ## reads the threshold matrix of `chipName`
  withDatabase:
    let dsetName = joinPath(chipNameToGroup(chipName), ThresholdPrefix)
    var dset = h5f[dsetName.dset_str]
    result = dset[int64].toTensor.reshape(256, 256).asType(int)

proc writeTotCalibAttrs(h5f: var H5FileObj, chip: string, fitRes: FitResult) =
  ## writes the fit results as attributes to the H5 file for `chip`
  # group object to write attributes to
  var mgrp = h5f[chip.grp_str]
  # map parameter names to their position in FitResult parameter seq
  const parMap = { "a" : 0,
                   "b" : 1,
                   "c" : 2,
                   "t" : 3 }.toTable
  mgrp.attrs["TOT Calibration"] = "performed at " & $now()
  for key, val in parMap:
    mgrp.attrs[key] = fitRes.pRes[val]
    mgrp.attrs[&"{key}_err"] = fitRes.pErr[val]

proc calibrateType(tcKind: TypeCalibrate) =
  ## calibrates the given type and stores the fit results as attributes
  ## of each chip with valid data for calibration
  # open H5 file with write access
  var h5f = H5file(db, "rw")
  case tcKind
  of TotCalibrate:
    # perform TOT calibration for all chips, which contain a TOT
    # calibration
    # - get groups in root of file == chips in file
    # - get TOT object of each chip
    # - perform Fit as in plotCalibration
    # - take `mpfit` result and save fit parameters as attrs
    for group in h5f.items(depth = 1):
      # group name is the chip name
      let chip = group.name
      echo "Getting TOT for chip ", chip
      let tot = getTotCalib(chip)
      let totCalib = fitToTCalib(tot, 0.0)
      # given fit result write attributes:
      h5f.writeTotCalibAttrs(chip, totCalib)
    
  of SCurveCalibrate:
    discard

  let err = h5f.close()
  if err < 0:
    echo "Could not properly close database! err = ", err


proc parseCalibrateType(typeStr: string): TypeCalibrate =
  ## checks the given `typeStr` whether it's a valid type to
  ## calibrate for. If so returns that type, else raises an
  ## exception
  case typeStr.toLower
  of $TotCalibrate:
    result = TotCalibrate
  of $SCurveCalibrate:
    result = ScurveCalibrate
  else:
    raise newException(KeyError, "Given type is not a valid type to calibrate " &
      """for. Valid types are ["TOT", "SCurve"] (case insensitive)""")
    
proc parseChipInfo(filename: string): Chip =
  ## parses the `chipInfo` file and returns a chip object from that
  let info = readFile(filename).splitLines
  assert match(info[0], ChipNameLineReg), "The chipInfo file needs to contain the " &
    "`chipName: ` as the first line"
  let chipStr = info[0].split(':')[1].strip
  # fill the `name` field
  result.name = parseChipName(chipStr)
  # parse the optional content of further notes on the chip
  # e.g. board, chip number on that board etc.
  result.info = initTable[string, string]()
  for line in info[1 .. info.high]:
    if line.len > 0:
      if ':' in line:
        let
          lineSplit = line.split(':')
          n = lineSplit[0].strip
          c = lineSplit[1].strip
        result.info[n] = c
      else:
        # support for lines without a key
        result.info[line.strip] = ""
    
proc parseFsr(filename: string): FSR =
  ## parses the contents of a (potential) given FSR file
  ## uses regex `FsrContentReg` to parse the file
  echo "Filename is ", filename
  if existsFile(filename) == true:
    let fLines = readFile(filename).splitLines
    var dacVal: array[2, string]
    result = initTable[string, int]()
    for line in fLines:
      if match(line.strip, FsrContentReg, dacVal):
        result[dacVal[0]] = dacVal[1].parseInt

proc parseScurveFolder(folder: string): SCurveSeq =
  ## parses all SCurve files (matching `SCurveReg`) in the folder
  ## and returns an `SCurveSeq` from it
  var scurveMatch: array[1, string]
  echo folder
  for f in walkFiles(joinPath(folder, SCurvePattern)):
    if match(f, SCurveReg, scurveMatch):
      result.files.add f
      let voltage = scurveMatch[0].parseInt
      let scurve = readScurveVoltageFile(f)
      result.curves.add scurve

proc parseTotFile(filename: string): Tot =
  ## checks for the existence of a TOT calibration file, reads it
  ## and returns a `Tot` object
  if existsFile(filename) == true:
    let (chip, tot) = readToTFile(filename,
                                  startRead = StartTotRead,
                                  totPrefix = TotPrefix)
    result.pulses = tot.pulses
    result.mean = tot.mean
    result.std = tot.std

proc parseThresholdFile(filename: string): Threshold =
  ## parses a Threshold(Means) file and returns it
  echo filename
  let flat = readFile(filename).splitLines -->
    map(it.splitWhitespace) -->
    flatten() -->
    map(it.parseInt)
  result = flat.toTensor().reshape([256, 256])

proc writeThreshold(h5f: var H5FileObj, threshold: Threshold, chipGroupName: string) =
  var thresholdDset = h5f.create_dataset(joinPath(chipGroupName, ThresholdPrefix),
                                          (256, 256),
                                          dtype = int)
  thresholdDset[thresholdDset.all] = threshold.data.reshape([256, 256])
  

proc addChipToH5(chip: Chip,
                 fsr: FSR,
                 scurves: SCurveSeq,
                 tot: Tot,
                 threshold: Threshold,
                 thresholdMeans: ThresholdMeans) =
  ## adds the given chip to the InGrid database H5 file

  var h5f = H5File(dbPath, "rw")
  var chipGroup = h5f.create_group($chip.name)
  # add FSR, chipInfo to chipGroup attributes
  for key, value in chip.info:
    echo &"Appending {key} with {value}"
    chipGroup.attrs[key] = if value.len > 0: value else: "nil"
  for dac, value in fsr:
    chipGroup.attrs[dac] = value

  # SCurve groups
  if scurves.files.len > 0:
    var scurveGroup = h5f.create_group(joinPath(chipGroup.name, SCurveFolder))
    for i, f in scurves.files:
      # for each file write a dataset
      let curve = scurves.curves[i]
      var scurveDset = h5f.create_dataset(joinPath(scurveGroup.name,
                                                   curve.name),
                                          (curve.thl.len, 2),
                                          dtype = int)
      # reshape the data to be two columns of [thl, hits] pairs and write
      scurveDset[scurveDset.all] = zip(curve.thl, curve.hits).mapIt(@[it[0], it[1]])
      # add voltage of dataset as attribute (for easier reading)
      scurveDset.attrs["voltage"] = curve.voltage

  if tot.pulses.len > 0:
    # TODO: replace the TOT write by a compound data type using TotType
    # that allows us to easily name the columns too!
    echo sizeof(TotType)
    var totDset = h5f.create_dataset(joinPath(chipGroup.name, TotPrefix),
                                     (tot.pulses.len, 3),
                                     dtype = float)
    # sort of ugly conversion to 3 columns, using double zip
    # since we don't have a zip for more than 2 seqs
    totDset[totDset.all] = zip(zip(tot.pulses.asType(float),
                               tot.mean),
                               tot.std).mapIt(@[it[0][0],
                                                it[0][1],
                                                it[1]])

  if threshold.shape == @[256, 256]:
    h5f.writeThreshold(threshold, chipGroup.name)

  #if thresholdMeans.shape == @[256, 256]:
  #  h5f.writeThreshold(thresholdMeans, chipGroup.name)    
  
  let err = h5f.close()

        
proc addChip(folder: string) =
  ## handles adding the data for a chip from a folder
  ## it parses all available data in the folder and adds it to the correct group
  ## in the database file
  ## the given folder needs to conform to a few things to be parsed properly:
  ## Folder structure:
  ## - chipInfo.txt
  ##   Contains:
  ##     - chipName: <name as given in TOS>
  ##     - arbitrary lines, which are individually added as string attributes for
  ##       this chips group. If lines have a colon, the string before that is the
  ##       name of the attribute
  ## Optional: if the following exists, it will be added
  ## - fsr?.txt
  ##   The FSR file of that chip
  ## - threshold?.txt
  ##   The threshold equalization of that chip
  ## - thresholdMeans?.txt                         
  ##   The mean values of threshold equalization of that chip
  ## - SCurve/
  ##   A folder containing the SCurves for that chip
  ## - TOTCalib?.txt
  ##   the TOT calibrration of that chip
  assert dirExists(folder), "Please hand an existing folder!"
  assert existsFile joinPath(folder, ChipInfo), "The given folder needs to contain a `chipInfo.txt`!"

  # read chip info file
  let chip = parseChipInfo joinPath(folder, ChipInfo)
  echo "Chip is ", chip

  # after chip check for fsr
  var fsrFileName = ""
  for f in walkFiles(joinPath(folder, FsrPattern)):
    echo f
    fsrFileName = f
  let fsr = parseFsr fsrFileName
  if fsr.len > 0:
    echo fsr
  
  # check for SCurves
  var scurves: SCurveSeq
  if dirExists(joinPath(folder, SCurveFolder)) == true:
    scurves = parseScurveFolder(joinPath(folder, SCurveFolder))

  # check for TOT
  var tot: Tot
  for f in walkFiles(joinPath(folder, TotPattern)):
    tot = parseTotFile(f)

  # check for threshold / threshold means
  var
    threshold: Threshold
    thresholdMeans: ThresholdMeans
  for f in walkFiles(joinPath(folder, ThresholdPattern)):
    threshold = parseThresholdFile(f)
  #for f in walkFiles(joinPath(folder, ThresholdMeansPattern)):
    #thresholdMeans = parseThresholdFile(f)
  #  assert false, "Threshold means writing not yet implemented!"

  # given all data, add it to the H5 file
  addChipToH5(chip, fsr, scurves, tot, threshold, thresholdMeans)

proc main() =

  let args = docopt(doc)
  echo args

  let
    addStr = $args["--add"]
    calibrateStr = $args["--calibrate"]
    modifyStr = $args["--modify"]
    deleteStr = $args["--delete"]

  if modifyStr != "false":
    assert false, "Modify support is not implmented yet."
  elif deleteStr != "nil":
    assert false, "Delete support is not implmented yet."
  elif calibrateStr != "nil":
    calibrateType calibrateStr.parseCalibrateType
  else:
    # call proc to add data from folder to database
    addChip(addStr)  

when isMainModule:
  main()
    