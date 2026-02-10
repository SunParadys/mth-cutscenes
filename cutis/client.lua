-- "https://sunparadys.tebex.io"

local ESX = exports["es_extended"]:getSharedObject()

local PRE_CUTSCENE_SKIN = nil
local HD_AREA = nil

local function fetchPlayerSkinSync()
  local p = promise.new()
  ESX.TriggerServerCallback('esx_skin:getPlayerSkin', function(skin)
    p:resolve(skin)
  end)
  return Citizen.Await(p)
end

local function restorePlayerSkin()
  if not PRE_CUTSCENE_SKIN then return end

  local ped = PlayerPedId()

  TriggerEvent('skinchanger:loadSkin', PRE_CUTSCENE_SKIN)
  TriggerEvent('esx_skin:loadSkin', PRE_CUTSCENE_SKIN)

  ClearPedTasksImmediately(ped)
  ClearAllPedProps(ped)
  SetPedDefaultComponentVariation(ped)
end

local Config = json.decode(LoadResourceFile(GetCurrentResourceName(), "config.json")) or {}

----------------------------------------------------
-- SETTINGS
----------------------------------------------------
local MENU_CMD  = "cut"   -- /cut
local MENU_KEY  = "F2"   -- Keybind
local PAGE_SIZE = 100
local PRE_CUTSCENE_SKIN = nil

-- Stop-Tasten (X + ESC / Back)
local STOP_KEYS = {
  { group = 0, key = 73  }, -- X  (INPUT_VEH_DUCK)
  { group = 0, key = 177 }, -- BACKSPACE/Cancel
  { group = 2, key = 202 }, -- ESC (Frontend Cancel)
}

local function uniq(list)
  local seen, out = {}, {}
  for i = 1, #list do
    local v = list[i]
    if type(v) == "string" and v ~= "" and not seen[v] then
      seen[v] = true
      out[#out+1] = v
    end
  end
  table.sort(out)
  return out
end

local function clamp(n, a, b)
  if n < a then return a end
  if n > b then return b end
  return n
end

local CUTSCENES = uniq(Config)

----------------------------------------------------
-- FAVORITEN (KVP)
----------------------------------------------------
local FAV_KVP = "sun_cutscene_favs_v2"
local FavList = {}  
local FavSet  = {}   

local function rebuildFavSet()
  FavSet = {}
  for i = 1, #FavList do
    local n = FavList[i]
    if type(n) == "string" and n ~= "" then
      FavSet[n] = true
    end
  end
end

local function loadFavs()
  local raw = GetResourceKvpString(FAV_KVP)
  if raw and raw ~= "" then
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == "table" then
      FavList = data
      rebuildFavSet()
      return
    end
  end
  FavList = {}
  rebuildFavSet()
end

local function saveFavs()
  SetResourceKvp(FAV_KVP, json.encode(FavList))
end

local function isFav(name)
  return FavSet[name] == true
end

local function toggleFav(name)
  if isFav(name) then
    -- remove
    local out = {}
    for i = 1, #FavList do
      if FavList[i] ~= name then out[#out+1] = FavList[i] end
    end
    FavList = out
  else
    FavList[#FavList+1] = name
  end

  rebuildFavSet()
  saveFavs()
end

local function favListSorted()
  local out = {}
  for i = 1, #FavList do out[#out+1] = FavList[i] end
  table.sort(out)
  return out
end

CreateThread(function()
  loadFavs()
end)

----------------------------------------------------
-- CUTSCENE STOP (X / ESC)
----------------------------------------------------
local function hardStopCutscene()
  if IsCutsceneActive() or IsCutscenePlaying() then
    StopCutsceneImmediately()
  end

  RenderScriptCams(false, true, 0, true, true)
  DestroyAllCams(true)

  SetNuiFocus(false, false)
  ClearFocus()

  local ped = PlayerPedId()
  ClearPedTasksImmediately(ped)
  FreezeEntityPosition(ped, false)
  SetEntityVisible(ped, true)
  
  if HD_AREA then
    ClearHdArea()
    HD_AREA = nil
  end
  
  ClearHdArea()
  ClearFocus()

  restorePlayerSkin()

  DoScreenFadeIn(250)
  ESX.ShowHelpNotification("Cutscene abgebrochen")
end

CreateThread(function()
  while true do
    if IsCutsceneActive() or IsCutscenePlaying() then
      Wait(0)

      ESX.ShowHelpNotification("~INPUT_VEH_DUCK~ oder ~INPUT_FRONTEND_CANCEL~ Cutscene abbrechen")
	  -- ShowNotification("~o~X~s~ oder ~o~ESC~s~ Cutscene abbrechen")

      for i = 1, #STOP_KEYS do
        DisableControlAction(STOP_KEYS[i].group, STOP_KEYS[i].key, true)
      end

      for i = 1, #STOP_KEYS do
        if IsDisabledControlJustReleased(STOP_KEYS[i].group, STOP_KEYS[i].key) then
          hardStopCutscene()
          break
        end
      end
    else
      Wait(250)
    end
  end
end)

local function ForceWorldStreamingAroundCoords(coords, radius, ms)
  radius = radius or 250.0
  ms = ms or 8000

  ClearFocus()
  SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)
  SetHdArea(coords.x, coords.y, coords.z, radius)

  RequestCollisionAtCoord(coords.x, coords.y, coords.z)
  RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)

  NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, radius, 0)

  local deadline = GetGameTimer() + ms
  while GetGameTimer() < deadline do
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)

    if HasCollisionLoadedAroundEntity(PlayerPedId()) and not IsNetworkLoadingScene() then
      break
    end
    Wait(0)
  end

  NewLoadSceneStop()

  local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
  if interior ~= 0 then
    LoadInterior(interior)
    local t2 = GetGameTimer() + 3000
    while not IsInteriorReady(interior) and GetGameTimer() < t2 do
      Wait(0)
    end
  end
end
----------------------------------------------------
-- CUTSCENE PLAY
----------------------------------------------------
local function PlayCutscene(name)
  if type(name) ~= "string" or name == "" then return end

  local ped = PlayerPedId()
  local coords = GetEntityCoords(ped)
  local heading = GetEntityHeading(ped)

  DoScreenFadeOut(300)
  while not IsScreenFadedOut() do Wait(0) end

  PRE_CUTSCENE_SKIN = fetchPlayerSkinSync()

  if IsCutsceneActive() or IsCutscenePlaying() then
    StopCutsceneImmediately()
    Wait(0)
  end

  ClearFocus()
  SetFocusPosAndVel(coords.x, coords.y, coords.z, 0.0, 0.0, 0.0)
  SetHdArea(coords.x, coords.y, coords.z, 120.0)
  HD_AREA = true

  RequestCollisionAtCoord(coords.x, coords.y, coords.z)
  RequestAdditionalCollisionAtCoord(coords.x, coords.y, coords.z)

  NewLoadSceneStart(coords.x, coords.y, coords.z, coords.x, coords.y, coords.z, 120.0, 0)
  local t = GetGameTimer() + 7000
  while IsNetworkLoadingScene() and GetGameTimer() < t do
    Wait(0)
  end
  NewLoadSceneStop()
  
  local coords = GetEntityCoords(PlayerPedId())
  ForceWorldStreamingAroundCoords(coords, 300.0, 10000)

  RequestCutscene(name, 8)
  local timeout = GetGameTimer() + 12000
  while not HasCutsceneLoaded() do
    Wait(0)
    if GetGameTimer() > timeout then
      DoScreenFadeIn(200)
      ESX.ShowHelpNotification("Cutscene konnte nicht geladen werden: " .. name)
      return
    end
  end
  
  TriggerEvent('save_all_clothes') 
  
  SetCutsceneEntityStreamingFlags('MP_1', 0, 1)
  RegisterEntityForCutscene(ped, 'MP_1', 0, 0, 64)

  SetCutsceneEntityStreamingFlags('MP_2', 0, 1)
  RegisterEntityForCutscene(ped, 'MP_2', 0, 0, 64)

  SetCutsceneEntityStreamingFlags('MP_3', 0, 1)
  RegisterEntityForCutscene(ped, 'MP_3', 0, 0, 64)

  SetCutsceneEntityStreamingFlags('MP_4', 0, 1)
  RegisterEntityForCutscene(ped, 'MP_4', 0, 0, 64)
  
  DoScreenFadeIn(200)
  StartCutscene(0)
  
  local coords2 = GetEntityCoords(PlayerPedId())
  ForceWorldStreamingAroundCoords(coords2, 350.0, 6000)

  while not (DoesCutsceneEntityExist('MP_1', 0)) do
    Wait(5)
  end
  
  SetCutscenePedComponentVariationFromPed(PlayerPedId(), GetPlayerPed(-1), 1885233650)
  SetPedComponentVariation(GetPlayerPed(-1), 11, jacket_old, jacket_tex, jacket_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 8, shirt_old, shirt_tex, shirt_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 3, arms_old, arms_tex, arms_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 4, pants_old,pants_tex,pants_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 6, feet_old,feet_tex,feet_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 1, mask_old,mask_tex,mask_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 2, hair_old,hair_tex,hair_pal)
  SetPedComponentVariation(GetPlayerPed(-1), 9, vest_old,vest_tex,vest_pal)
  SetPedPropIndex(GetPlayerPed(-1), 0, hat_prop, hat_tex, 0)
  SetPedPropIndex(GetPlayerPed(-1), 1, glass_prop, glass_tex, 0)

   while not (HasCutsceneFinished()) do
      Wait(5)
   end
	
  CreateThread(function()
    while IsCutsceneActive() or IsCutscenePlaying() do
      Wait(200)
    end

    RenderScriptCams(false, true, 0, true, true)
    DestroyAllCams(true)
    ClearFocus()

    if HD_AREA then
      ClearHdArea()
      HD_AREA = nil
    end

    SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
    SetEntityHeading(ped, heading)
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true)

    restorePlayerSkin()

    DoScreenFadeIn(250)
  end)
end

RegisterNetEvent('save_all_clothes') 
AddEventHandler('save_all_clothes',function()
    local ped = PlayerPedId()
    mask_old,mask_tex,mask_pal = GetPedDrawableVariation(ped,1),GetPedTextureVariation(ped,1),GetPedPaletteVariation(ped,1)
    vest_old,vest_tex,vest_pal = GetPedDrawableVariation(ped,9),GetPedTextureVariation(ped,9),GetPedPaletteVariation(ped,9)
    glass_prop,glass_tex = GetPedPropIndex(ped,1),GetPedPropTextureIndex(ped,1)
    hat_prop,hat_tex = GetPedPropIndex(ped,0),GetPedPropTextureIndex(ped,0)
    hair_old,hair_tex,hair_pal = GetPedDrawableVariation(ped,2),GetPedTextureVariation(ped,2),GetPedPaletteVariation(ped,2)
    jacket_old,jacket_tex,jacket_pal = GetPedDrawableVariation(ped, 11),GetPedTextureVariation(ped,11),GetPedPaletteVariation(ped,11)
    shirt_old,shirt_tex,shirt_pal = GetPedDrawableVariation(ped,8),GetPedTextureVariation(ped,8),GetPedPaletteVariation(ped,8)
    arms_old,arms_tex,arms_pal = GetPedDrawableVariation(ped,3),GetPedTextureVariation(ped,3),GetPedPaletteVariation(ped,3)
    pants_old,pants_tex,pants_pal = GetPedDrawableVariation(ped,4),GetPedTextureVariation(ped,4),GetPedPaletteVariation(ped,4)
    feet_old,feet_tex,feet_pal = GetPedDrawableVariation(ped,6),GetPedTextureVariation(ped,6),GetPedPaletteVariation(ped,6)
end)

----------------------------------------------------
-- OX MENU
----------------------------------------------------
local function ShowCutscenePage(title, list, page, backMenuId, isFavorites)
  page = page or 1
  local pages = math.max(1, math.ceil(#list / PAGE_SIZE))
  page = clamp(page, 1, pages)

  local startIndex = (page - 1) * PAGE_SIZE + 1
  local endIndex = math.min(page * PAGE_SIZE, #list)

  local opts = {}

  opts[#opts+1] = {
    title = ("Seite %d/%d  (%d–%d von %d)"):format(page, pages, startIndex, endIndex, #list),
    disabled = true
  }

  if page > 1 then
    opts[#opts+1] = {
      title = "◀ Vorherige Seite",
      icon = "chevron-left",
      onSelect = function()
        ShowCutscenePage(title, list, page - 1, backMenuId, isFavorites)
      end
    }
  end

  if page < pages then
    opts[#opts+1] = {
      title = "Nächste Seite ▶",
      icon = "chevron-right",
      onSelect = function()
        ShowCutscenePage(title, list, page + 1, backMenuId, isFavorites)
      end
    }
  end

  opts[#opts+1] = { title = "────────────", disabled = true }

  if #list == 0 then
    opts[#opts+1] = { title = "Keine Einträge", disabled = true }
  else
    for i = startIndex, endIndex do
      local name = list[i]
      local starred = isFav(name)

      opts[#opts+1] = {
        title = (starred and ("⭐ " .. name) or name),
        description = "Starten (X stoppt) • Favorit verwalten",
        icon = starred and "star" or "play",
        onSelect = function()
          local starredNow = isFav(name)

          lib.registerContext({
            id = "sun_cutscene_item",
            title = name,
            menu = "sun_cutscene_page",
            options = {
              {
                title = "▶ Starten",
                icon = "play",
                onSelect = function()
                  PlayCutscene(name)
                end
              },
              {
			    title = starredNow and "⭐ Favorit entfernen" or "⭐ Zu Favoriten",
			    icon = "star",
			    onSelect = function()
				  toggleFav(name)

				  CreateThread(function()
				    Wait(0)
				    local refreshList = list
				    if isFavorites then
					  refreshList = favListSorted()
				    end
				    ShowCutscenePage(title, refreshList, page, backMenuId, isFavorites)
				  end)
			    end
			  }
            }
          })

          lib.showContext("sun_cutscene_item")
        end
      }
    end
  end

  lib.registerContext({
    id = "sun_cutscene_page",
    title = title,
    menu = backMenuId,
    options = opts
  })

  lib.showContext("sun_cutscene_page")
end

function OpenCutsceneMenuOx()
  local favList = favListSorted()

  local options = {
    {
	  title = "⭐ Favoriten",
	  description = "Deine gespeicherten Cutscenes",
	  icon = "star",
	  onSelect = function()
		local list = favListSorted()
		ShowCutscenePage("⭐ Favoriten", list, 1, "sun_cutscene_main", true)
	  end
	},
    {
      title = "Suche",
      description = "Cutscene suchen (zeigt max. 100 Treffer pro Seite)",
      icon = "magnifying-glass",
      onSelect = function()
        local input = lib.inputDialog("Cutscene suchen", {
          { type = "input", label = "Suchbegriff", placeholder = "z.B. xm4 oder mcs" }
        })
        if not input or not input[1] or input[1] == "" then return end

        local q = string.lower(input[1])
        local results = {}

        for i = 1, #CUTSCENES do
          local cs = CUTSCENES[i]
          if string.find(string.lower(cs), q, 1, true) then
            results[#results+1] = cs
          end
        end

        ShowCutscenePage(("Suche: %s"):format(input[1]), results, 1, "sun_cutscene_main")
      end
    },
    {
      title = "Alle Cutscenes (Seiten)",
      description = ("%d Cutscenes, %d pro Seite"):format(#CUTSCENES, PAGE_SIZE),
      icon = "list",
      onSelect = function()
        ShowCutscenePage("Alle Cutscenes", CUTSCENES, 1, "sun_cutscene_main")
      end
    }
  }

  lib.registerContext({
    id = "sun_cutscene_main",
    title = "Cutscene Menü",
    options = options
  })

  lib.showContext("sun_cutscene_main")
end

----------------------------------------------------
-- COMMAND + KEYBIND
----------------------------------------------------
RegisterCommand(MENU_CMD, function()
  OpenCutsceneMenuOx()
end, false)

CreateThread(function()
  while not lib do Wait(100) end
  if lib.addKeybind then
    lib.addKeybind({
      name = "open_cutscene_menu",
      description = "Cutscenen Menü",
      defaultKey = MENU_KEY,
      onPressed = function()
        OpenCutsceneMenuOx()
      end
    })
  end
end)

----------------------------------------------------
-- STANDART NOTIFICATION
----------------------------------------------------
function ShowNotification(text)
	SetNotificationTextEntry('STRING')
    AddTextComponentString(text)
	DrawNotification(false, true)
end