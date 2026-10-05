//+------------------------------------------------------------------+
//|                                                   SMC_Config.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  User configuration profiles: save / load the runtime settings   |
//|  from the control panel without restarting the EA.               |
//|                                                                  |
//|  Format: plain "key=value" text, one setting per line, written to |
//|  MQL5\Files\SMC_OrderBlock_EA\<profile>.cfg (or the common folder)|
//|                                                                  |
//|  Saved:    every user-adjustable runtime setting (panel state)   |
//|            plus a read-only snapshot of the EA inputs.           |
//|  Not saved: market state (OB / CISD ids, retests, prices).       |
//|                                                                  |
//|  Loading starts from the CURRENT state, so unknown or missing    |
//|  keys keep their present value, and everything is clamped by     |
//|  CSMCPanel::SetState() -> Sanitize().                            |
//+------------------------------------------------------------------+
#ifndef SMC_CONFIG_MQH
#define SMC_CONFIG_MQH

#include "SMC_OB_Panel.mqh"

#define SMC_CFG_FOLDER  "SMC_OrderBlock_EA"
#define SMC_CFG_VERSION 1

struct SSMCConfigResult
  {
   bool              ok;
   int               applied;        // known keys read
   int               unknown;        // keys this build does not know
   int               inputDiff;      // "input." entries differing from the running inputs
   string            message;
  };

//+------------------------------------------------------------------+
string SMC_ConfigPath(const string profile)
  {
   string name = profile;
   StringTrimLeft(name);
   StringTrimRight(name);
   if(name == "")
      name = "default";
   //--- keep the file name safe
   StringReplace(name, "\\", "_");
   StringReplace(name, "/", "_");
   StringReplace(name, ":", "_");
   StringReplace(name, "*", "_");
   StringReplace(name, "?", "_");
   StringReplace(name, "\"", "_");
   StringReplace(name, "<", "_");
   StringReplace(name, ">", "_");
   StringReplace(name, "|", "_");
   return SMC_CFG_FOLDER + "\\" + name + ".cfg";
  }

//+------------------------------------------------------------------+
void SMC_CfgWrite(const int h, const string key, const string value)
  {
   FileWriteString(h, key + "=" + value + "\r\n");
  }

void SMC_CfgWriteInt(const int h, const string key, const int value)
  {
   SMC_CfgWrite(h, key, IntegerToString(value));
  }

void SMC_CfgWriteBool(const int h, const string key, const bool value)
  {
   SMC_CfgWrite(h, key, value ? "1" : "0");
  }

//+------------------------------------------------------------------+
//| Save the panel state (+ an input snapshot) as a profile           |
//+------------------------------------------------------------------+
bool SMC_ConfigSave(const string profile, const SSMCPanelState &p, const string inputSnapshot,
                    const bool common, SSMCConfigResult &res)
  {
   ZeroMemory(res);
   string path = SMC_ConfigPath(profile);
   int flags = FILE_WRITE | FILE_TXT | FILE_ANSI | (common ? FILE_COMMON : 0);
   ResetLastError();
   int h = FileOpen(path, flags);
   if(h == INVALID_HANDLE)
     {
      res.ok = false;
      res.message = StringFormat("cannot write %s (error %d)", path, GetLastError());
      return false;
     }

   SMC_CfgWrite(h, "# SMC Order Block EA configuration", "");
   SMC_CfgWriteInt(h, "version", SMC_CFG_VERSION);
   SMC_CfgWrite(h, "saved", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
   SMC_CfgWrite(h, "symbol", _Symbol);

   //--- panel / runtime settings
   SMC_CfgWriteBool(h, "collapsed", p.collapsed);
   SMC_CfgWriteBool(h, "easyMode", p.easyMode);
   SMC_CfgWriteBool(h, "showBull", p.showBull);
   SMC_CfgWriteBool(h, "showBear", p.showBear);
   SMC_CfgWriteBool(h, "showInactive", p.showInactive);
   SMC_CfgWriteBool(h, "showBOS", p.showBOS);
   SMC_CfgWriteBool(h, "showFVG", p.showFVG);
   SMC_CfgWriteBool(h, "showRetest", p.showRetest);
   SMC_CfgWriteBool(h, "showLabels", p.showLabels);
   SMC_CfgWriteBool(h, "showSwings", p.showSwings);
   SMC_CfgWriteBool(h, "fillZones", p.fillZones);
   SMC_CfgWriteBool(h, "showRetestStart", p.showRetestStart);
   SMC_CfgWriteBool(h, "cisdSweep", p.cisdSweep);
   SMC_CfgWriteBool(h, "cisdConfirm", p.cisdConfirm);
   SMC_CfgWriteBool(h, "cisdRetrace", p.cisdRetrace);
   SMC_CfgWriteInt(h, "tfPair", p.tfPair);
   SMC_CfgWriteInt(h, "obTF", p.obTF);
   SMC_CfgWriteInt(h, "cisdTF", p.cisdTF);
   SMC_CfgWriteBool(h, "connect", p.connect);
   SMC_CfgWriteInt(h, "cisdMode", p.cisdMode);
   SMC_CfgWriteInt(h, "retestMode", p.retestMode);
   SMC_CfgWriteBool(h, "mitStopsCISD", p.mitStopsCISD);
   SMC_CfgWriteBool(h, "trendFilter", p.trendFilter);
   SMC_CfgWrite(h, "trendGate", DoubleToString(p.trendGate, 2));
   SMC_CfgWriteBool(h, "tradeEnabled", p.tradeEnabled);
   SMC_CfgWrite(h, "lots", DoubleToString(p.lots, 2));
   SMC_CfgWriteBool(h, "oppositeExit", p.oppExit);
   SMC_CfgWrite(h, "targetRR", DoubleToString(p.targetRR, 1));
   SMC_CfgWriteBool(h, "rideTrend", p.rideTrend);
   SMC_CfgWriteBool(h, "entryAlert", p.entryAlert);
   SMC_CfgWriteBool(h, "riskPctMode", p.riskPctMode);
   SMC_CfgWrite(h, "riskPercent", DoubleToString(p.riskPercent, 2));
   SMC_CfgWriteBool(h, "breakEven", p.breakEven);
   SMC_CfgWriteInt(h, "bePoints", p.bePoints);
   SMC_CfgWriteInt(h, "swingLength", p.swingLength);
   SMC_CfgWrite(h, "dispATRMult", DoubleToString(p.dispATRMult, 2));
   SMC_CfgWriteInt(h, "maxOBToBOSBars", p.maxOBToBOSBars);
   SMC_CfgWriteInt(h, "maxActivePerDir", p.maxActivePerDir);
   SMC_CfgWriteInt(h, "fvgMode", p.fvgMode);
   SMC_CfgWriteInt(h, "mitigationMode", p.mitigationMode);
   SMC_CfgWriteInt(h, "invalidationMode", p.invalidationMode);
   SMC_CfgWriteInt(h, "overlapMode", p.overlapMode);

   //--- read-only snapshot of the EA inputs (cannot be applied at runtime, reported on load)
   if(inputSnapshot != "")
      FileWriteString(h, inputSnapshot);

   FileClose(h);
   res.ok = true;
   res.message = StringFormat("saved %s", path);
   return true;
  }

//+------------------------------------------------------------------+
//| Load a profile into the panel state (in / out: current state)     |
//+------------------------------------------------------------------+
bool SMC_ConfigLoad(const string profile, SSMCPanelState &p, const bool common,
                    string &inputKeys[], string &inputValues[], SSMCConfigResult &res)
  {
   ZeroMemory(res);
   ArrayResize(inputKeys, 0);
   ArrayResize(inputValues, 0);
   string path = SMC_ConfigPath(profile);
   int flags = FILE_READ | FILE_TXT | FILE_ANSI | (common ? FILE_COMMON : 0);
   ResetLastError();
   int h = FileOpen(path, flags);
   if(h == INVALID_HANDLE)
     {
      res.ok = false;
      res.message = StringFormat("cannot read %s (error %d)", path, GetLastError());
      return false;
     }

   int version = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "" || StringGetCharacter(line, 0) == '#')
         continue;
      int sep = StringFind(line, "=");
      if(sep <= 0)
         continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      StringTrimLeft(key);
      StringTrimRight(key);
      StringTrimLeft(val);
      StringTrimRight(val);
      int    iv = (int)StringToInteger(val);
      bool   bv = (iv != 0);
      double dv = StringToDouble(val);

      if(StringFind(key, "input.") == 0)
        {
         int n = ArraySize(inputKeys);
         ArrayResize(inputKeys, n + 1);
         ArrayResize(inputValues, n + 1);
         inputKeys[n] = StringSubstr(key, 6);
         inputValues[n] = val;
         continue;
        }

      res.applied++;
      if(key == "version")                 version = iv;
      else if(key == "saved" || key == "symbol") res.applied--;   // informational
      else if(key == "collapsed")          p.collapsed = bv;
      else if(key == "easyMode")           p.easyMode = false;   // Easy mode was removed
      else if(key == "showBull")           p.showBull = bv;
      else if(key == "showBear")           p.showBear = bv;
      else if(key == "showInactive")       p.showInactive = bv;
      else if(key == "showBOS")            p.showBOS = bv;
      else if(key == "showFVG")            p.showFVG = bv;
      else if(key == "showRetest")         p.showRetest = bv;
      else if(key == "showLabels")         p.showLabels = bv;
      else if(key == "showSwings")         p.showSwings = bv;
      else if(key == "fillZones")          p.fillZones = bv;
      else if(key == "showRetestStart")    p.showRetestStart = bv;
      else if(key == "cisdSweep")          p.cisdSweep = bv;
      else if(key == "cisdConfirm")        p.cisdConfirm = bv;
      else if(key == "cisdRetrace")        p.cisdRetrace = bv;
      else if(key == "tfPair")             { p.tfPair = iv; p.obTF = SMC_PairOBIndex(iv); p.cisdTF = SMC_PairCISDIndex(iv); }
      else if(key == "obTF")               { p.tfPair = SMC_PairFromOBIndex(iv); p.obTF = SMC_PairOBIndex(p.tfPair); }
      else if(key == "cisdTF")             p.cisdTF = SMC_PairCISDIndex(p.tfPair);   // tied to the pair
      else if(key == "connect")            p.connect = bv;
      else if(key == "cisdMode")           p.cisdMode = iv;
      else if(key == "retestMode")         p.retestMode = iv;
      else if(key == "mitStopsCISD")       p.mitStopsCISD = bv;
      else if(key == "trendFilter")        p.trendFilter = bv;
      else if(key == "trendGate")          p.trendGate = dv;
      else if(key == "tradeEnabled")       p.tradeEnabled = bv;
      else if(key == "lots")               p.lots = dv;
      else if(key == "oppositeExit")       p.oppExit = bv;
      else if(key == "targetRR")           p.targetRR = dv;
      else if(key == "rideTrend")          p.rideTrend = bv;
      else if(key == "entryAlert")         p.entryAlert = bv;
      else if(key == "riskPctMode")        p.riskPctMode = bv;
      else if(key == "riskPercent")        p.riskPercent = dv;
      else if(key == "breakEven")          p.breakEven = bv;
      else if(key == "bePoints")           p.bePoints = iv;
      else if(key == "swingLength")        p.swingLength = iv;
      else if(key == "dispATRMult")        p.dispATRMult = dv;
      else if(key == "maxOBToBOSBars")     p.maxOBToBOSBars = iv;
      else if(key == "maxActivePerDir")    p.maxActivePerDir = iv;
      else if(key == "fvgMode")            p.fvgMode = iv;
      else if(key == "mitigationMode")     p.mitigationMode = iv;
      else if(key == "invalidationMode")   p.invalidationMode = iv;
      else if(key == "overlapMode")        p.overlapMode = iv;
      else
        {
         res.applied--;
         res.unknown++;                     // newer / older build: ignored, current value kept
        }
     }
   FileClose(h);

   if(version <= 0 || version > SMC_CFG_VERSION)
     {
      res.ok = (version > 0);
      res.message = StringFormat("%s: unsupported version %d", path, version);
      if(!res.ok)
         return false;
     }
   res.ok = true;
   if(res.message == "")
      res.message = StringFormat("loaded %s (%d settings, %d unknown)", path, res.applied, res.unknown);
   return true;
  }

bool SMC_ConfigExists(const string profile, const bool common)
  {
   return FileIsExist(SMC_ConfigPath(profile), common ? FILE_COMMON : 0);
  }

#endif // SMC_CONFIG_MQH
