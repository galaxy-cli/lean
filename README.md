# lean

A small command-line tool for tracking your weight and calorie intake, and for estimating your calorie deficit and body fat percentage.

It's a single Python script with no dependencies. Your data is stored locally in a SQLite database, and nothing leaves your machine.

## Features

- Store a profile (sex, age, height, weight, calorie intake, activity level)
- Log weight and intake as often as you like; the latest value of each is always used
- Calculate your daily calorie deficit or surplus and estimated weekly weight change
- Estimate body fat percentage from neck, waist (and hip) measurements
- Show the body fat ranges for each category, matched to your sex
- Project how much weight and how many weeks it would take to move from one body fat percentage to another
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
lean -p -e                # set up your profile, weight and intake
lean -d                   # see your daily deficit
lean --wl                 # see calorie targets for weight loss
lean --bf -e              # log neck/waist measurements
lean --bf                 # see your body fat estimate
lean --bf 22 17           # how long to go from 22% to 17% body fat
lean --bf -r              # body fat ranges for each category
lean --all                # show everything at once
```

## Commands

Each topic has a short form and longer aliases; they all do the same thing.

| Topic | Options | Shows |
| --- | --- | --- |
| Profile | `-p`, `--profile` | Sex, age, height, weight, intake, activity level |
| Body fat | `--bf`, `--bfp`, `--bodyfat`, `--body-fat-percentage` | Estimated body fat % and category |
| Deficit | `-d`, `--deficit` | Today's calorie deficit or surplus |
| Weight loss | `--wl`, `--weight-loss`, `--weightloss` | Your TDEE and calorie targets for weight loss |
| All | `--all` | Profile, body fat, deficit and weight loss in one go |

Modifiers:

| Option | Meaning |
| --- | --- |
| `-e`, `--edit` | Update values instead of showing them |
| `-c`, `--clear` | With `-e`, delete all stored data for the topic |
| `-y`, `--yes` | Skip the `--clear` confirmation |
| `-r`, `--range` | With `--bf`, show the body fat ranges for each category |

### Common commands

| Command | What it does |
| --- | --- |
| `lean -p` | Show your profile, weight and intake |
| `lean -p -e` | Update your profile, weight and intake |
| `lean --bf` | Show your estimated body fat % and category |
| `lean --bf -e` | Log neck and waist (and hip for women) measurements |
| `lean --bf -r` | Show the body fat ranges (obese to essential fat) for your sex |
| `lean --bf 22 17` | Project the weight change and time to go from 22% to 17% body fat |
| `lean --bf 17` | Same, starting from your measured body fat |
| `lean -d` | Show today's calorie deficit or surplus |
| `lean -d -e` | Quickly log just weight and intake |
| `lean --wl` | Show your TDEE and calorie targets for weight loss |
| `lean --all` | Show all four reports back to back |
| `lean -p -e -c` | Delete all stored profile data (including weight and intake) |
| `lean --bf -e -c` | Delete all stored body fat measurements |

### Combining options

You can give more than one topic, and they run in the order you type them:

```bash
lean -p --bfp -e      # edit your profile, then your body fat measurements
lean --bf -p          # show body fat, then your profile
lean -p --bf -e -c    # clear your profile, then your body fat measurements
```

Short flags can be bundled, so `lean -pe` is the same as `lean -p -e`. If one topic can't run (for example, you haven't logged measurements yet), the rest still run and `lean` exits with status 1 at the end.

`--wl` and `--all` are calculated from your other data, so they can't be edited or cleared. The same goes for clearing `-d`; to clear that data, clear your profile.

### Entering values

Units are flexible. Height defaults to centimeters and weight defaults to pounds if you don't give a unit. Body fat measurements are the exception: they must include `in` or `cm`.

| Value | Accepted formats |
| --- | --- |
| Height | `178cm`, `70in`, `5'10"`, or a bare number (cm) |
| Neck, waist, hip | `15in` or `38.1cm` (a unit is required; `15` alone is rejected) |
| Weight | `160lb`, `72kg`, or a bare number (lb); whole numbers like `228` are treated as `228.0` |
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

### Body fat ranges

`lean --bf -r` (or `--range`) lists the body fat categories from highest to lowest. The ranges differ by sex, so it uses the sex in your profile; if none is set yet, it shows both. If you've logged measurements, your own category is marked.

```
$ lean --bf -r
----- Body Fat Ranges (male) -----
Obese          25% or more
Average        18-24%
Fitness        14-17%   <- you (17.4%)
Athletes       6-13%
Essential Fat  5% or less
```

The female ranges are Obese 32% or more, Average 25-31%, Fitness 21-24%, Athletes 14-20%, and Essential Fat 13% or less. `-r` only goes with `--bf`, and can't be combined with `--all`, `--edit`, `--clear` or percentages.

### Body fat projection

`lean --bodyfat CURRENT GOAL` estimates how much fat you'd lose (or gain) and how long it would take. Give one number (`lean --bodyfat 17`) to use your measured body fat as the starting point. It needs your latest weight, and uses your TDEE and intake when they're available.

```
$ lean --bodyfat 22 17
----- Body Fat Projection -----
Body fat:        22.0% -> 17.0%
Weight:          160.0 lb -> 150.4 lb
Fat to lose:     9.6 lb (4.4 kg)

Estimated time:
  At your intake (2200 kcal, 0.85 lb/wk): ~11 weeks (~2.6 months)
  At 0.5 lb/wk (~2375 kcal/day): ~19 weeks (~4.4 months)
  At 1.0 lb/wk (~2125 kcal/day): ~10 weeks (~2.2 months)

(Rough estimate: assumes your lean mass stays the same and 3,500 kcal = 1 lb of fat.)
```

The time estimates are shown at your current intake (if it moves you toward the goal) and at 0.5 and 1.0 lb/week. For a loss, a rate that would put you below the general safe minimum intake is flagged.

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
- **Projection:** assumes your lean mass stays the same, so the whole weight change is fat: goal weight = lean mass / (1 - goal body fat). Time is the fat change divided by the weekly rate, at 3,500 kcal per pound.
- **Safe minimum warning:** if your logged intake is below the higher of the 2 lb/week target or a general floor (1,500 kcal for men, 1,200 kcal for women), `lean` prints a warning. This shows after logging an intake and in `--deficit` and `--weightloss`. It never blocks you from logging a value.

## Where your data lives

Everything is stored in a single SQLite file:

```
~/.local/share/lean/lean.db
```

It's created automatically on first run. Each edit adds a new timestamped row rather than overwriting old values, and `lean` always uses the most recent value of each field. The only time rows are removed is when you use `--clear`. To back up or reset everything, copy or delete that file.

## Disclaimer

`lean` gives rough estimates based on general formulas. It is not medical advice. Talk to a doctor or registered dietitian before making major changes to your diet.
