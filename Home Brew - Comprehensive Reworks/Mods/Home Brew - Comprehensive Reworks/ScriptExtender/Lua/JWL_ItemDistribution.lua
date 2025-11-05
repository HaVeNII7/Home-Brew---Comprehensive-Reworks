-- Distributions will be saved to PersistentVars to avoid repeats. This is per-save file.
PersistentVars = {
	
}

local function OnSessionLoaded()        
	-- Define the containers to distribute items to.
	local itemDistArrayDI = {
		{
			npcName = "Act 3 Hag Lair Chest",
			npcMapKey = "6e969ce2-48b5-49e1-9bce-e95d248fbc7c",
			itemName = "Dragon Totem",
			itemUUID = "d89aab5b-7ada-4663-aa18-62742de7a502",
			addEquip = false
		},
		{
			npcName = "Aelis Siryasius",
			npcMapKey = "5a4f7f77-43c9-4f84-b3f4-4076d876ccde",
			itemName = "Dragon Bloodwell Vial",
			itemUUID = "c4b4ba06-e2ff-48da-ac76-762ee9625520",
			addEquip = true
		},
		{
			npcName = "Allandra Grey",
			npcMapKey = "32d78583-07c6-4160-9ec7-3a24b15149c8",
			itemName = "Sea Serpent's Pin",
			itemUUID = "a9dae592-7f06-4757-b45e-2e4269d2e37a",
			addEquip = true
		},
		{
			npcName = "Ansur",
			npcMapKey = "67770922-5e0a-40c5-b3f0-67e8eb50493a",
			itemName = "Empowered Guardian Emblem",
			itemUUID = "68ae2a78-57fc-4a10-9271-afe10dcc50c0",
			addEquip = true
		},
		{
			npcName = "Astral Prism Potion Pouch",
			npcMapKey = "6b3c0a8e-c3a2-478d-bea5-bfe58af34852",
			itemName = "Mimir",
			itemUUID = "a60af61c-6bca-48f4-8e7d-5f5d996f78b4",
			addEquip = false
		},
		{
			npcName = "Balthazar",
			npcMapKey = "53651a9f-7ea8-444f-ba2d-224390b72f7d",
			itemName = "Thayan Femur",
			itemUUID = "15d86bdd-71b7-4481-b175-8d0b43733f51",
			addEquip = true
		},
		{
			npcName = "Bernard",
			npcMapKey = "5038c0f2-0022-4699-82ce-a319b30616bb",
			itemName = "Docent",
			itemUUID = "4443b3fd-8235-43d3-98de-0592307de2d7",
			addEquip = false
		},
		{
			npcName = "Blythe",
			npcMapKey = "336fe388-afbe-4b9b-a86e-aec927658019",
			itemName = "Red Ioun Stone",
			itemUUID = "39238dd1-5b49-4712-a8d9-a53d9c1d1751",
			addEquip = true
		},
		{
			npcName = "Brewers Hidden Stash",
			npcMapKey = "e262054d-8e98-48b9-9ed0-58128eb6388b",
			itemName = "Hourglass of Distorted Perception",
			itemUUID = "83147bb1-aad8-4410-8433-f30956d94f2e",
			addEquip = false
		},
		{
			npcName = "Bulette",
			npcMapKey = "307934b5-6fb5-4fdc-a7ff-433a7ba175b3",
			itemName = "Mourningsteel Obol",
			itemUUID = "912d054a-82cb-4295-9961-609b61b35041",
			addEquip = false
		},
		{
			npcName = "Cazador Szarr",
			npcMapKey = "2f1880e6-1297-4ca3-a79c-9fabc7f179d3",
			itemName = "Kerzins Ooze",
			itemUUID = "22cb3882-1e5f-4873-8367-7385d248f577",
			addEquip = true
		},
		{
			npcName = "Chrai Harrak",
			npcMapKey = "54467aa9-33dd-41c4-bd77-87a71ed22c16",
			itemName = "Compendium of Furtive Techniques",
			itemUUID = "48927a1a-035b-431e-8a9f-d5894724cf43",
			addEquip = true
		},
		{
			npcName = "Chrai Wwargaz",
			npcMapKey = "378ac93e-03a0-40b4-904c-f37989ac7a8c",
			itemName = "Mourningsteel Warbanner",
			itemUUID = "abd813fb-ca1d-4417-91ed-b3fc22c64248",
			addEquip = true
		},
		{
			npcName = "Dhourn",
			npcMapKey = "1f86d2de-db96-4662-a360-6ba5ad902fd7",
			itemName = "Pearl of Power",
			itemUUID = "23a0cbcc-62cc-4721-9283-a846e921774b",
			addEquip = true
		},
		{
			npcName = "Dolor",
			npcMapKey = "55837c0f-0171-4020-a4a3-dd6de7ffc134",
			itemName = "Green Ioun Stone",
			itemUUID = "bcd2b91c-ac07-4b9c-a907-690edf8377ca",
			addEquip = true
		},
		{
			npcName = "Dowry Chest",
			npcMapKey = "d7368244-74f3-46f6-9198-d0dd81d72a78",
			itemName = "Balance of Harmony",
			itemUUID = "9080213f-7468-41fa-9682-448f76122708",
			addEquip = false
		},
		{
			npcName = "Fake Jaheira",
			npcMapKey = "4da802f5-3237-40b8-afff-d728016e3047",
			itemName = "Yellow Ioun Stone",
			itemUUID = "dca93175-bb3a-4356-82a1-3a1e99d649ab",
			addEquip = true
		},
		{
			npcName = "Fake Dribbles",
			npcMapKey = "21f541c1-e1bc-49a8-888f-d8a330c47336",
			itemName = "Purple Ioun Stone",
			itemUUID = "750755d8-02af-4dcd-866d-d2d83fc96e43",
			addEquip = true
		},
		{
			npcName = "Father Lorgan",
			npcMapKey = "75fd6462-4d79-4d36-8fdc-fbdd124f5722",
			itemName = "Holy Symbol of Ilmater",
			itemUUID = "e3e557ba-f62b-480e-bf99-6b026a41158e",
			addEquip = false
		},
		{
			npcName = "Family Ring Chest",
			npcMapKey = "85f9b25a-8e9d-4c01-9fc4-d557ff61b8e6",
			itemName = "Lens of Astute Observation",
			itemUUID = "766b3db3-e7a1-4d73-b3e0-d08402108bc8",
			addEquip = false
		},
		{
			npcName = "Flind",
			npcMapKey = "34464430-fed8-4f50-86d5-bd35846920a0",
			itemName = "Belt of Primal Recall",
			itemUUID = "ae588c38-3e1b-4f38-97b2-635c76164527",
			addEquip = true
		},
		{
			npcName = "Flind Loot",
			npcMapKey = "34464430-fed8-4f50-86d5-bd35846920a0",
			itemName = "Belt of Primal Recall Loot",
			itemUUID = "ae588c38-3e1b-4f38-97b2-635c76164527",
			addEquip = false
		},
		{
			npcName = "Filro",
			npcMapKey = "2f00e363-09b2-4573-badc-f0995bef6610",
			itemName = "Vaulting Pole",
			itemUUID = "c8e8f20b-4f1a-4fcd-a823-31c16643396b",
			addEquip = true
		},
		{
			npcName = "Gekh Coal",
			npcMapKey = "05c338d9-4590-4c4b-b87e-8c27ea2c2b18",
			itemName = "Belt of Dwarven Kind",
			itemUUID = "31c71ff2-7049-4380-8987-2ea958e92b98",
			addEquip = true
		},
		{
			npcName = "Gomwicks Corpse",
			npcMapKey = "bf842d88-0c39-48b8-b4a1-f9ab140ee6ca",
			itemName = "Beast Masters Whistle",
			itemUUID = "a75cda5b-f92f-403b-a550-7e041b87b49c",
			addEquip = false
		},
		{
			npcName = "Gorions Tomb",
			npcMapKey = "09cc519c-f242-4628-addb-ba436c6bba99",
			itemName = "Orb of Imminent Scrying",
			itemUUID = "46886b26-7cf4-407e-aefc-8668a788f412",
			addEquip = false
		},
		{
			npcName = "Gortash",
			npcMapKey = "b878a854-f790-4999-95c4-3f20f00f65ac",
			itemName = "Book of Exalted Deeds",
			itemUUID = "e27ea56a-a48f-4379-96b8-e2bea0ce8fce",
			addEquip = true
		},
		{
			npcName = "Grove Booyagh",
			npcMapKey = "6a03d0ff-a930-4347-bba2-9f3fd6bc317a",
			itemName = "Goblin Bloodwell",
			itemUUID = "6bcdc3d7-32af-4317-846e-206db09e0a85",
			addEquip = true
		},
		{
			npcName = "Hag Lair Chest",
			npcMapKey = "40d6f1ee-921f-42e3-ad26-166ca338a047",
			itemName = "Witchs Whistle",
			itemUUID = "3a76eeba-ab0e-4b92-9ab7-48df94e6e4c6",
			addEquip = false
		},
		{
			npcName = "Haarlep",
			npcMapKey = "3947e0e2-3b4c-4a39-ac53-454e95665b26",
			itemName = "Dimensional Shackles",
			itemUUID = "c873730b-a2fd-41c5-9120-ff4766497b34",
			addEquip = true
		},
		{
			npcName = "Harpy Chest",
			npcMapKey = "a5c87ab6-b38b-4c2b-bf4f-a1f5f391f79f",
			itemName = "Galders Bubble Pipe",
			itemUUID = "3d5b0195-04eb-4c73-97ea-7817ab928c00",
			addEquip = false
		},
		{
			npcName = "Herdmaster Skorjall",
			npcMapKey = "90780cde-9241-478f-83a8-58a4a7d151fe",
			itemName = "Holy Symbol of Moradin",
			itemUUID = "43237b7d-9f23-4599-854d-0270be42308f",
			addEquip = true
		},
		{
			npcName = "Hhune Secret Chest",
			npcMapKey = "e7ca86c1-d867-413d-82fb-251700f8f5d1",
			itemName = "Holy Symbol of Correlon",
			itemUUID = "c8ff4f81-a21a-41ff-915b-9301d01b29bf",
			addEquip = false
		},
		{
			npcName = "High Secrity Vault n3",
			npcMapKey = "b0df3609-7395-48cc-a419-63e8172629d8",
			itemName = "Dimensional Quiver",
			itemUUID = "f5a0b316-712c-4d4c-8cac-6cd13b360f71",
			addEquip = false
		},
		{
			npcName = "Houndmaster Pol Grave",
			npcMapKey = "9449dac8-e7e7-4509-82f7-da9b36de3129",
			itemName = "Cerberus Whistle",
			itemUUID = "0f0e391d-01cf-4c05-844d-e03d3a244a77",
			addEquip = false
		},
		{
			npcName = "House of Hope Treasure Pile",
			npcMapKey = "0278d4ae-3e7c-4c1e-a4bc-fbf99db35e02",
			itemName = "Belt of Forbidden Harmony",
			itemUUID = "ae778557-df31-4081-b33d-c1549903e5b2",
			addEquip = false
		},
		{
			npcName = "Infernal Marble Chest",
			npcMapKey = "264aa8a6-1028-4c2f-8a43-095aa9cc27fc",
			itemName = "Orb of Skoraeus",
			itemUUID = "5944880b-3e3c-442c-9233-e0b60d5cdd1f",
			addEquip = false
		},
		{
			npcName = "Kevo Phogge",
			npcMapKey = "c24f4c4a-58ad-4c82-b968-5eb7c422993c",
			itemName = "Blue Ioun Stone",
			itemUUID = "533cb022-3b0f-433a-b98d-dc7efb2b32f6",
			addEquip = true
		},
		{
			npcName = "Kithrak Therezzyn",
			npcMapKey = "5093da9b-237a-491f-9402-4f9da73c1565",
			itemName = "Belt of Frost Giant Strength",
			itemUUID = "b3e45e8a-bc43-48a9-a5be-40be40084ad0",
			addEquip = true
		},
		{
			npcName = "Korrilla",
			npcMapKey = "d432aafd-f728-4d9d-9707-732e1cdd8297",
			itemName = "War Banner of Infernal Power",
			itemUUID = "73b96be4-a2fd-44d1-bbb6-5127bc7200e8",
			addEquip = true
		},
		{
			npcName = "Last Light Cellar Chest",
			npcMapKey = "8a628fa5-e19d-4887-b9c4-863b9194eea2",
			itemName = "Tome of Celestial Healing",
			itemUUID = "7667fbb6-6a1a-44fa-a35b-288055a10a02",
			addEquip = false
		},
		{
			npcName = "Lolth Cultist Chest",
			npcMapKey = "e8f726d4-aacd-4397-adaa-27ebdf6a0f5b",
			itemName = "Holy Symbol of Lolth",
			itemUUID = "bda4d2e2-288d-45ff-9d67-31cb072ac507",
			addEquip = false
		},
		{
			npcName = "Lorroakan",
			npcMapKey = "a9d4b71d-b0ef-429e-8210-6dc8be986ee9",
			itemName = "Arcane Codex",
			itemUUID = "fb7d1253-d6a0-4c08-8800-5ff8306c7b40",
			addEquip = true
		},
		{
			npcName = "Moonrise Balcony Chest",
			npcMapKey = "d427fbde-5322-4ef1-96b3-08780780a421",
			itemName = "Dread Totem",
			itemUUID = "201faba1-7cd6-4b0f-ad7f-c9ff9560ef0d",
			addEquip = false
		},
		{
			npcName = "Moonrise Hidden Chest",
			npcMapKey = "fcc39731-9c3d-4b7d-bac6-7d634e2ad476",
			itemName = "Tome of Lost Knowledge",
			itemUUID = "877d4060-efa9-418b-b2c7-2a5584b27b6a",
			addEquip = false
		},
		{
			npcName = "Moonrise Mimic",
			npcMapKey = "8571d22f-7e86-4f29-8a41-220c2ef3473f",
			itemName = "Bag of Tricks",
			itemUUID = "4352b7a5-cbbe-48e5-b02e-8def9020661c",
			addEquip = false
		},
		{
			npcName = "Morgue Harper Corpse",
			npcMapKey = "f210c0f6-a8ec-44d9-8114-4ecbfd8ac0dc",
			itemName = "Handy Haversack",
			itemUUID = "8932df29-e031-4486-8736-2e508e506a2a",
			addEquip = false
		},
		{
			npcName = "Mystic Carrion",
			npcMapKey = "b003409c-364f-4065-94bf-7436001d890e",
			itemName = "Gibbering Bell",
			itemUUID = "ca3dcb1e-0212-4f91-9180-f05ba91353d2",
			addEquip = true
		},
		{
			npcName = "Orin",
			npcMapKey = "bf24e0ec-a3a6-4905-bd2d-45dc8edf8101",
			itemName = "Book of Vile Darkness",
			itemUUID = "fb89ecd5-e61f-496e-b8fe-68e6af181809",
			addEquip = true
		},
		{
			npcName = "Prelate Liric",
			npcMapKey = "fd75dc6e-6a8d-4d9d-8cfc-ca4ff5da53d7",
			itemName = "Worghide Leather Frog",
			itemUUID = "ca2ab06d-0e1e-4b95-a5e4-47ac91a74af4",
			addEquip = true
		},
		{
			npcName = "Pooldripp",
			npcMapKey = "a1f879ab-8731-4889-9b7b-d91b5094dbc0",
			itemName = "Candle of Lawful Invocation",
			itemUUID = "baf8e075-56cf-429a-8a77-65106aac46f1",
			addEquip = true
		},
		{
			npcName = "Raphael",
			npcMapKey = "f65becd6-5cd7-4c88-b85e-6dd06b60f7b8",
			itemName = "Dealbreaker",
			itemUUID = "2724b253-7acc-4171-9797-74576330f9cc",
			addEquip = true
		},
		{
			npcName = "Reithwin Graveyard Robe Tomb",
			npcMapKey = "ec9f28cf-f9d9-4e12-b1d6-3aded6316df2",
			itemName = "Holy Symbol of Bahamut",
			itemUUID = "c7989a33-c853-4e3f-8678-fd2e95d528fc",
			addEquip = false
		},
		{
			npcName = "Rosymorn Roof Chest",
			npcMapKey = "4bf6d779-37b7-49c6-9098-69d65475a171",
			itemName = "Cowardly Carpet of Flying",
			itemUUID = "f6ed4d26-3522-44e2-89a9-4cd1cdec9be8",
			addEquip = false
		},
		{
			npcName = "Sarevok Anchev",
			npcMapKey = "ae9f784a-ea64-4297-95a7-8377e85231b6",
			itemName = "Pink Ioun Stone",
			itemUUID = "f71c1eb4-b73b-45b9-addc-5bb625bd7bb5",
			addEquip = true
		},
		{
			npcName = "Skrut",
			npcMapKey = "5bac0842-c1d4-4358-a85c-24ab745d0280",
			itemName = "Goblin Banner",
			itemUUID = "c86e638b-93c8-4187-a14f-8e06917c9517",
			addEquip = true
		},
		{
			npcName = "Sparkswall Chest",
			npcMapKey = "99ef091e-23b0-4dea-8c5e-956e73500543",
			itemName = "Professor Orb",
			itemUUID = "c45ea160-68f2-44ad-99e3-00d0294c868a",
			addEquip = false
		},
		{
			npcName = "Sundries Vault Chest 1",
			npcMapKey = "ca9faeb1-503c-4b80-bee3-eb003e85e7e4",
			itemName = "Bag of Holding",
			itemUUID = "c706b371-f58a-440b-9eb3-9c643bf83286",
			addEquip = false
		},
		{
			npcName = "Sundries Vault Chest 2",
			npcMapKey = "e3deb5f7-9f2e-4320-9245-56fac6767173",
			itemName = "Skeleton Key",
			itemUUID = "6310deff-a0c1-45c8-a152-15b3713d41dd",
			addEquip = false
		},
		{
			npcName = "Thayan Cellar Chest",
			npcMapKey = "36d1ffed-dbc1-4bce-9414-27b7e1344c15",
			itemName = "Infernal Archive",
			itemUUID = "eae0289f-96db-447f-8fa4-12d3a224657f",
			addEquip = false
		},
		{
			npcName = "Tollhouse Locked Chest",
			npcMapKey = "dc40b9c3-b3ca-482d-a29e-7040e69f7682",
			itemName = "Holy Symbol of Eilistraee",
			itemUUID = "68b94726-3d18-4fad-a376-ca9ba297f5f9",
			addEquip = false
		},
		{
			npcName = "Viconia DeVir",
			npcMapKey = "b1ea974d-96fb-47ca-b6d9-9c85fcb69313",
			itemName = "Tome of Ethereal Currents",
			itemUUID = "7e30bf41-4fa9-45ae-85da-797b00504a1a",
			addEquip = true
		},
		{
			npcName = "Withers Chest",
			npcMapKey = "01a2d8b6-1f4b-4b8c-b463-55aea56113d3",
			itemName = "Holy Symbol of Kelemvor",
			itemUUID = "fa05689e-5367-4ddd-8dab-0139db3677be",
			addEquip = false
		},
		{
			npcName = "Xargrim",
			npcMapKey = "a38523e2-7630-402e-8036-17cfe5397fe0",
			itemName = "Ruby of the Warmage",
			itemUUID = "fada4b90-c873-4628-b30f-695895a0fee0",
			addEquip = false
		},
		{
			npcName = "Yurgir",
			npcMapKey = "1dc8091d-2af6-4d33-9268-998ef266d19c",
			itemName = "Silver Lycan Charm",
			itemUUID = "c4d45206-9201-4eca-b835-628ad31a8941",
			addEquip = true
		},
		{
			npcName = "Zrell",
			npcMapKey = "8e75eb3b-7551-485e-8f98-2bf2e51d3e84",
			itemName = "Corrupted Bloodwell Vial",
			itemUUID = "2c5fce17-edd2-421d-b5da-65c8a2cfba8b",
			addEquip = true
		}
	}
	
	-- Stringify itemDistArrayDI for easier parsing
	local json = Ext.Json.Stringify(itemDistArrayDI)
	-- _P("Printing Discordant Instruments distribution list to console:")
	-- _P(json)
	local distArray = Ext.Json.Parse(json)

	-- Run distribution
	function OnLevelLoaded()
		_P("Distributing items for mod: JWL Discordant Instruments")
		for itemCount = 1, #distArray do
			local item = distArray[itemCount]
			if PersistentVars[item.npcName:gsub('%W','') .. item.itemName:gsub('%W','')] ~= true and Osi.TemplateIsInInventory(item.itemUUID, item.npcMapKey) ~= nil and Osi.TemplateIsInInventory(item.itemUUID, item.npcMapKey) < 1 then
				Osi.TemplateAddTo(item.itemUUID, item.npcMapKey, 1)
				_P(item.itemName, "distributed to inventory of", item.npcName)
				PersistentVars[item.npcName:gsub('%W','') .. item.itemName:gsub('%W','')] = true
			else
				-- Just some extra logging for easier debugging
				if PersistentVars[item.npcName:gsub('%W','') .. item.itemName:gsub('%W','')] == true then
					_P(item.itemName, "has already been distributed to", item.npcName)
				end
				if Osi.TemplateIsInInventory(item.itemUUID, item.npcMapKey) == nil then
					_P(item.npcName, "cannot be found or is invalid")
				end
			end
		end
		_P("Distribution complete: saving distributions to PersistentVars")
	end
	
	function UnequipExistingItems(target, slot)
		local slotString = getSlot(slot)
		local GUID = GetGUID(target)
		if (GetEquippedItem(GUID,slotString) ~= nil) then
			item_to_unequip = GetEquippedItem(GUID, slotString)
			LockUnequip(item_to_unequip, 0)
			Unequip(GUID,item_to_unequip)
		end		
	end

	function GetGUID(str)
		return string.sub(str,-36)
	end

	function getSlot(slot)
		local TrinketSlots = {
			"Helmet",
			"Breast",
			"Cloak",
			"MeleeMainHand",
			"MeleeOffHand",
			"RangedMainHand",
			"RangedOffHand",
			"Ring",
			"Underwear",
			"Boots",
			"Gloves",
			"Amulet",
			"Ring2",
			"Wings",
			"Horns",
			"Overhead",
			"MusicalInstrument",
			"VanityBody",
			"VanityBoots"
		}
		return TrinketSlots[slot + 1]
	end

	Ext.Osiris.RegisterListener("TemplateAddedTo", 4, "after", function (wpn_root, wpn_id, character, useless)
		for itemCount = 1, #distArray do
			local item = distArray[itemCount]
			if item.itemUUID == GetGUID(wpn_root) then
				if (item.addEquip == true and GetGUID(character) == item.npcMapKey and IsPartyMember(character, 1) == 0) then
					_P(character, "is attempting to equip trinket")
					if (IsEquipable(wpn_id) == 1) then
						local slot = GetEquipmentSlotForItem(wpn_id)          
						UnequipExistingItems(character, slot)
						_P(character, "successfully equipped", wpn_root)
						Equip(character, wpn_id)
					end 
				end
			end
		end
	end)
	Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", OnLevelLoaded)
end

Ext.Events.SessionLoaded:Subscribe(OnSessionLoaded)