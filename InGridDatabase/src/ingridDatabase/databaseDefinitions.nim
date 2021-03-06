import strutils, ospaths, re, tables

# helper proc to remove the ``src`` which is part of `nimble path`s output
# this is a bug, fix it.
proc removeSuffix(s: string, rm: string): string {.compileTime.} =
  result = s
  result.removeSuffix(rm)
    
const ingridPath* = staticExec("nimble path ingridDatabase").removeSuffix("src")
const db = "resources/ingridDatabase.h5"
const dbPath* = joinPath(ingridPath, db)

const
  ChipInfo* = "chipInfo.txt"
  FsrPrefix* = "fsr"
  FsrPattern* = "fsr*.txt"
  TotPrefix* = "TOTCalib"
  TotPattern* = TotPrefix & r"*\.txt"
  ThresholdPrefix* = "threshold"
  ThresholdPattern* = r"threshold[0-9]\.txt"
  ThresholdMeansPrefix* = ThresholdPrefix & "Means"
  ThresholdMeansPattern* = ThresholdPrefix & r"Means*\.txt"
  SCurvePrefix* = "voltage_"
  SCurveRegPrefix* = r".*" & SCurvePrefix
  SCurvePattern* = r"voltage_*\.txt"
  SCurveFolder* = "SCurve/"
  StartTotRead* = 20.0
let
  ChipNameLineReg* = re(r"chipName:")
  ChipNameReg* = re(r".*([A-Z])\s*([0-9]+)\s*W\s*([0-9]{2}).*")
  FsrReg* = re(FsrPrefix & r"([0-9])\.txt")
  FsrContentReg* = re(r"(\w+)\s([0-9]+)")
  TotReg* = re(TotPrefix & r"([0-9])\.txt")
  SCurveReg* = re(SCurveRegPrefix & r"([0-9]+)\.txt")

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

  # type to store results of fitting with mpfit
  FitResult* = object
    x*: seq[float]
    y*: seq[float]
    pRes*: seq[float]
    pErr*: seq[float]
    redChiSq*: float

proc `$`*(chip: ChipName): string =
  result = $chip.col & $chip.row & " W" & $chip.wafer

    
