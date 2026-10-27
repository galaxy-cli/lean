# lean

A small command-line tool for tracking your weight and calorie intake, and for estimating your calorie deficit and body fat percentage.

It's a single Python script with no dependencies. Your data is stored locally in a SQLite database, and nothing leaves your machine.

## Features

- Store a profile (sex, age, height, weight, calorie intake, activity level)
- Log weight and intake as often as you like; the latest value of each is always used
- Calculate your daily calorie deficit or surplus and estimated weekly weight change
- Estimate body fat percentage from neck, waist (and hip) measurements
- See calorie targets for different rates of weight loss, with a warning if your intake is below a general safe minimum

## Requirements

- Python 3.6 or newer (standard library only)

## Installation

```bash
git clone <your-repo-url>
cd <your-repo-name>
chmod +x lean
```

To run it from anywhere, put it on your `PATH`:

```bash
mkdir -p ~/.local/bin
cp lean ~/.local/bin/lean
```

Or just run it in place with `./lean` or `python3 lean`.

## Quick start

```bash
lean --profile --edit     # set up your profile, weight and intake
lean --deficit            # see your daily deficit
lean --weightloss         # see calorie targets for weight loss
lean --bodyfat --edit     # log neck/waist measurements
lean --bodyfat            # see your body fat estimate
```

## Commands

| Command | What it does |
| --- | --- |
| `lean --profile` | Show your profile, weight and intake |
| `lean --profile --edit` | Update your profile, weight and intake |
| `lean --bodyfat` | Show your estimated body fat % and category |
| `lean --bodyfat --edit` | Log neck and waist (and hip for women) measurements |
| `lean --deficit` | Show today's calorie deficit or surplus |
| `lean --deficit --edit` | Quickly log just weight and intake |
| `lean --weightloss` | Show your TDEE and calorie targets for weight loss |
| `lean --profile --edit --clear` | Delete all stored profile data (including weight and intake) |
| `lean --bodyfat --edit --clear` | Delete all stored body fat measurements |

Add `-y` / `--yes` to `--clear` to skip the confirmation prompt.

`--weightloss` is calculated from your other data, so it can't be edited or cleared. The same goes for clearing `--deficit`; to clear that data, clear your profile.

### Entering values

Units are flexible. Lengths default to centimeters and weights default to pounds if you don't give a unit.

| Value | Accepted formats |
| --- | --- |
| Height | `178cm`, `70in`, `5'10"`, or a bare number (cm) |
| Neck, waist, hip | `38cm`, `15in`, or a bare number (cm) |
| Weight | `160lb`, `72kg`, or a bare number (lb) |
| Calories | `2000`, `2000kcal` |
| Sex | `m` or `f` |
| Activity level | `sedentary`, `light`, `moderate`, `very`, `athlete` |

When you run `--profile --edit`, the current value is shown in brackets; press Enter to keep it. Weight and intake can be skipped by pressing Enter, which records nothing.

## Example

```
$ lean --profile
----- Profile -----
Sex:             m
Age:             30
Height:          178.0cm (~5'10")
Weight:          160.0 lb (72.6 kg)
Intake:          2200 kcal
Activity level:  moderate

$ lean --deficit
----- Deficit -----
TDEE:            2625 kcal/day
Intake:          2200 kcal
Deficit:         -425 kcal/day
Est. weekly change: -0.85 lb (rough estimate)

$ lean --weightloss
----- Weightloss -----
TDEE:                    2625 kcal/day (maintenance)
Mild weight loss        (-0.5 lb/wk):  ~2375 kcal/day
Weight loss             (-1.0 lb/wk):  ~2125 kcal/day
Extreme weight loss     (-2.0 lb/wk):  ~1625 kcal/day
```

A height shown with `~` (like `~5'10"`) means the measurement is close to, but not exactly, that many feet and inches.

## How it works

- **TDEE** (total daily energy expenditure) is calculated with the Mifflin-St Jeor equation for BMR, multiplied by an activity factor:

  | Activity level | Multiplier |
  | --- | --- |
  | sedentary | 1.2 |
  | light | 1.375 |
  | moderate | 1.55 |
  | very | 1.725 |
  | athlete | 1.9 |

- **Deficit** is your TDEE minus your latest logged intake. Weekly change is estimated using 3,500 kcal per pound.
- **Body fat** uses the U.S. Navy method, then maps the result to an ACE category (Essential Fat, Athletes, Fitness, Average, Obese). It needs your profile (sex and height) plus neck and waist measurements, and hip for women.
- **Safe minimum warning:** if your logged intake is below the higher of the 2 lb/week target or a general floor (1,500 kcal for men, 1,200 kcal for women), `lean` prints a warning. This shows after logging an intake and in `--deficit` and `--weightloss`. It never blocks you from logging a value.

## Where your data lives

Everything is stored in a single SQLite file:

```
~/.local/share/lean/lean.db
```

It's created automatically on first run. Each edit adds a new timestamped row rather than overwriting old values, and `lean` always uses the most recent value of each field. The only time rows are removed is when you use `--clear`. To back up or reset everything, copy or delete that file.

## Disclaimer

`lean` gives rough estimates based on general formulas. It is not medical advice. Talk to a doctor or registered dietitian before making major changes to your diet.
