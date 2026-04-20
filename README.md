# DamageCap

A Windower addon that tracks whether your melee, ranged, and weapon skill damage is at attack cap versus the current mob. Determines capping via damage variance analysis rather than requiring enemy defense knowledge.

## Features

- **Capping Detection**: Uses variance ratio analysis to determine if damage is capped (~5% variance = capped).
- **Player Attack Stats**: Displays current attack power (base 8 + STR + weapon damage).
- **Damage Statistics**: Tracks min, max, average, and count for each damage type.
- **PDIF Estimation**: Calculates approximate PDIF using average damage.
- **Attack Buffs**: Shows active buffs affecting damage (Berserk, Aggressor, Haste, etc.).
- **Enemy Info**: Displays current target name and level.
- **Movable UI**: Drag to reposition the display.
- **Configurable**: Toggle visibility of each damage type.

## Display Information

Example output:
```
ATK: 487 | Buffs: Berserk Haste | Enemy: Abysmal Lord (Lvl 119)
Melee: CAPPED | PDIF: 2.05 | Avg: 205 | Min: 185 Max: 210 (6.8%)
Ranged: Uncapped | PDIF: 1.23 | Avg: 156 | Min: 120 Max: 180 (50.0%)
WS: CAPPED | PDIF: 3.12 | Avg: 642 | Min: 590 Max: 670 (13.6%)
```

Cap Detection Logic:
- Variance <= 7% with 4+ samples = CAPPED (natural 5% randomizer ceiling)
- Variance > 10% = Uncapped (room to grow with better gear/buffs)
- Variance 7-10% = Uncertain

## Commands

- `//damagecap show` or `//dc hide` - Toggle visibility.
- `//damagecap melee` - Toggle melee display.
- `//damagecap ranged` - Toggle ranged display.
- `//damagecap ws` - Toggle weapon skill display.
- `//damagecap reset` - Clear all damage data.

## How It Works

Since we don't know the enemy's defense, the addon infers attack cap status through damage variance:

1. **At Attack Cap**: Damage hits a ceiling determined by enemy DEF. With the 5% randomizer, damage variance will be about 5%.
2. **Below Attack Cap**: Damage scales with your attack. Variance will be higher (more spread), and adding attack buffs will increase average damage.

## Installation

Place the `damagecap` folder in your Windower addons directory (Windower/addons/damagecap/).

## Notes

- Base damage calculation is simplified and assumes standard fSTR formula.
- Attack value is base 8 + STR + weapon damage (gear attack bonuses not fully included yet).
- PDIF values are approximations and most accurate with larger sample sizes (10+ hits).
- Weapon skill PDIF caps vary by job; typical range is 2.0-4.0.