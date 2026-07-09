## Suggestion: Hybrid weapon spells should receive weapon bonuses once

### Problem

Some spell/cantrip-based weapon attacks currently sit between two bad outcomes:

- With broad flat `DamageBonus(...)`, a two-part spell such as Green-Flame Blade can receive the same weapon bonus on both the weapon hit and the spell rider.
- With the current suppressed weapon damage form, the same ability may receive no weapon-related damage bonus at all.

The tested case was `Target_GreenFlameBlade`. Changing only the actual `SpellSuccess` weapon hit from:

```txt
DealDamage(MainMeleeWeapon, MainMeleeWeaponDamageType,,,0,,true)
```

to:

```txt
DealDamage(MainMeleeWeapon, MainMeleeWeaponDamageType)
```

made Green-Flame Blade receive weapon-related bonus damage once, on the weapon hit, while the separate fire rider did not receive that bonus.

### Spell or ability entries

Spell/cantrip-based weapon attacks need a real weapon hit in the actual `SpellSuccess`. This controls whether the spell ability itself can receive weapon-related bonuses once.

For spell-based weapon attacks that are intended to count as weapon attacks, avoid suppressing the actual `SpellSuccess` weapon hit.

Use this for melee weapon hits:

```txt
DealDamage(MainMeleeWeapon, MainMeleeWeaponDamageType)
```

Use this for ranged weapon hits:

```txt
DealDamage(MainRangedWeapon, MainRangedWeaponDamageType)
```

or, when the spell uses `TARGET:` scope:

```txt
TARGET:DealDamage(MainRangedWeapon, MainRangedWeaponDamageType)
```

Keep the spell rider as a separate damage instance, for example:

```txt
DealDamage(LevelMapValue(D8Cantrip), Fire, Magical)
```

#### Spell or ability cases to review

These are spell-based weapon attacks found in 9.0.2. The entries marked `suppressed` use `,,,0,,true` on the actual `SpellSuccess` weapon hit and should be reviewed first.

##### Melee weapon spells with extra spell damage or riders

| Entry | File | Current weapon hit | Notes |
| --- | --- | --- | --- |
| `Target_StrikingIron` | `Classes Reworked (Cleric) - Spell_Target.txt` | suppressed | Fire cantrip rider |
| `Rush_DraconicBlitz` | `Classes Reworked (Fighter) - Spell_Rush.txt` | suppressed | Fire cantrip rider |
| `Target_EldritchStrike` | `Classes Reworked (Warlock) - Spell_Target.txt` | suppressed | Force rider and Eldritch Blast projectiles |
| `Target_EldritchStrike_2` to `Target_EldritchStrike_6` | `Classes Reworked (Warlock) - Spell_Target.txt` | suppressed | upcast/scaling variants |
| `Target_GalvanizedStrike` | `Feats Reworked - Spell_Target.txt` | suppressed | Lightning rider/projectile |
| `CTarget_MOO_Nightsong_SearingSmite` | `Feats Reworked - Spell_Target.txt` | suppressed | Radiant rider and burn status |
| `Target_ThunderousStrike` | `Spells Reworked - Spell_Target.txt` | suppressed | Thunder rider and Booming Blade status |
| `Target_GreenFlameBlade` | `Spells Reworked - Spell_Target.txt` | suppressed | Fire rider |
| `Target_SkyboundDive` | `Classes Reworked (Fighter) - Spell_Target.txt` | normal | already behaves correctly |
| `Target_DraconicMaul` | `Classes Reworked (Fighter) - Spell_Target.txt` | normal | likely already behaves correctly |

##### Ranged weapon spells with extra spell damage or riders

| Entry | File | Current weapon hit | Notes |
| --- | --- | --- | --- |
| `Projectile_ElementalFletching_Acid` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Acid rider |
| `Projectile_ElementalFletching_Fire` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Fire rider |
| `Projectile_ElementalFletching_Poison` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Poison rider |
| `Projectile_ElementalFletching_Psychic` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Psychic rider |
| `Projectile_ElementalFletching_Radiant` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Radiant rider |
| `Projectile_ElementalFletching_Thunder` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Thunder rider |
| `Projectile_ElementalFletching_Acid_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Acid rider |
| `Projectile_ElementalFletching_Cold_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Cold rider |
| `Projectile_ElementalFletching_Fire_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Fire rider; uses a save roll, so review separately |
| `Projectile_ElementalFletching_Lightning_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Lightning rider and extra projectile |
| `Projectile_ElementalFletching_Poison_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Poison rider |
| `Projectile_ElementalFletching_Thunder_Focused` | `Classes Reworked (Fighter) - Spell_Projectile.txt` | suppressed | Thunder rider |
| `Zone_ElementalFletching_Lightning` | `Classes Reworked (Fighter) - Spell_Zone.txt` | suppressed | Lightning rider; uses a save roll, so review separately |
| `Zone_ElementalFletching_Psychic_Focused` | `Classes Reworked (Fighter) - Spell_Zone.txt` | suppressed | Psychic rider; uses a save roll, so review separately |
| `Projectile_LightningArrow` | `Spells Reworked - Spell_Projectile.txt` | suppressed | Lightning target rider and AoE rider |
| `Projectile_LightningArrow_2` to `Projectile_LightningArrow_6` | `Spells Reworked - Spell_Projectile.txt` | suppressed | upcast/scaling variants |

##### Spell-based weapon attacks without an extra damage rider

These do not appear to have the same double-dip risk, but they should still be consistent about whether their weapon hit is allowed to receive weapon bonuses. `normal` here only means the actual weapon hit is not suppressed.

| Entry | File | Current weapon hit | Notes |
| --- | --- | --- | --- |
| `Projectile_SteelWindBeam` | `Classes Reworked (Wizard) - Spell_Projectile.txt` | suppressed | Arcane Warden / Steel Wind style weapon spell |
| `Projectile_SteelWindStrike` | `Classes Reworked (Wizard) - Spell_Target.txt` | normal | plain weapon hit |
| `Projectile_EnsnaringStrike` | `Spells Reworked - Spell_Projectile.txt` | normal | ranged weapon hit plus restrain status |
| `Target_EnsnaringStrike` | `Spells Reworked - Spell_Target.txt` | normal | melee weapon hit plus restrain status; variants `_2` to `_6` inherit it |
| `Projectile_HailOfThorns` | `Spells Reworked - Spell_Projectile.txt` | normal | ranged weapon hit plus separate thorn explosion |
| `Zone_ConjureBarrage_Melee` | `Spells Reworked - Spell_Zone.txt` | normal | melee container option; variants `_2` to `_6` inherit it |
| `Zone_ConjureBarrage_Ranged` | `Spells Reworked - Spell_Zone.txt` | normal | ranged container option; variants `_2` to `_6` inherit it |

This should allow weapon-spell attacks to receive the bonus once, without letting the spell rider double-dip. It also works better than checking only Bludgeoning/Piercing/Slashing, because some weapons can have Force, Psychic, Radiant, or other non-physical base damage types.

