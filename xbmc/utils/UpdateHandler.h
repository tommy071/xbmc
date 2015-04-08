#pragma once
/*
 *      Copyright (C) 2015 Team Kodi
 *      http://kodi.tv
 *
 *  This Program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This Program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with XBMC; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */
 
#include "IUpdater.h"
#include "settings/lib/ISettingCallback.h"
#include "settings/lib/ISettingsHandler.h"

class CSetting;

class CUpdateHandler : public IUpdater, public ISettingCallback, public ISettingsHandler
{
public:
  static CUpdateHandler &Get();

  // IUpdater
  virtual void Init();
  virtual void Deinit();
  virtual void SetAutoUpdateEnabled(bool enabled);
  virtual bool GetAutoUpdateEnabled();
  virtual void CheckForUpdate();
  virtual bool UpdateSupported();
  virtual bool HasExternalSettingsStorage();
  
  // ISettingCallback
  virtual void OnSettingAction(const CSetting *setting);
  virtual void OnSettingChanged(const CSetting *setting);

  // ISettingsHandler
  virtual void OnSettingsLoaded();
  
protected:
  CUpdateHandler();
  ~CUpdateHandler();

private:
  static IUpdater *impl;
  static CUpdateHandler sUpdateHandler;
};
 