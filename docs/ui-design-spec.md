# UI design guide

This guide describes the visual rules used by the application. Layout diagrams
are schematic; implementation tokens are defined in
[`LanghuanTheme`](../lib/shared/theme/app_theme.dart).

> Inspired by [Wise Design System](https://wise.design/) — clean, flat, borderless, generous white space.

## 1. Design principles

| Principle      | Description                                                                             |
| -------------- | --------------------------------------------------------------------------------------- |
| **Clean**      | Generous white space, minimal visual noise. Use the effective light, dark, or reader theme surface.               |
| **Flat**       | No drop shadows on cards. Differentiate with subtle background tints.                   |
| **Borderless** | Avoid visible borders. Use background colour contrast to separate areas.                |
| **Rounded**    | Large corner radii (10–32px mobile) for a bold, friendly feel.                          |
| **Readable**   | Optimised for long-form reading — clear typography hierarchy, comfortable line heights. |

---

## 2. Design tokens

### 2.1 Colour palette

Adapted from Wise's green-centric palette, tuned for a book-reading context.

#### Core colours

| Token                 | Light                            | Dark                   | Usage                               |
| --------------------- | -------------------------------- | ---------------------- | ----------------------------------- |
| `primary`             | Forest Green `#163300`           | Bright Green `#9FE870` | Interactive elements, active states |
| `accent`              | Bright Green `#9FE870`           | Forest Green `#163300` | Primary buttons, FAB, highlights    |
| `background.screen`   | `#FFFFFF`                        | `#121511`              | Base screen background              |
| `background.elevated` | `#FFFFFF`                        | `#1E2118`              | Bottom sheets, dialogs              |
| `background.neutral`  | `#F2F4EF` (8% Forest Green tint) | `#1E211B`              | Cards, chips, search bars           |
| `background.overlay`  | `#16330014` (8% opacity)         | `#9FE87014`            | Shimmers, loading overlays          |

#### Content colours

| Token               | Light     | Dark      | Usage                   |
| ------------------- | --------- | --------- | ----------------------- |
| `content.primary`   | `#0E0F0C` | `#E8EAE5` | Headlines, primary text |
| `content.secondary` | `#454745` | `#B0B2AD` | Body text, subtitles    |
| `content.tertiary`  | `#6A6C6A` | `#7D7F7C` | Placeholders, hints     |
| `content.link`      | `#163300` | `#9FE870` | Links, tappable text    |

#### Interactive colours

| Token                   | Light     | Dark      | Usage                            |
| ----------------------- | --------- | --------- | -------------------------------- |
| `interactive.primary`   | `#163300` | `#9FE870` | Active nav items, selected chips |
| `interactive.accent`    | `#9FE870` | `#163300` | Primary button background        |
| `interactive.secondary` | `#868685` | `#6A6C6A` | Input borders, secondary icons   |
| `interactive.control`   | `#163300` | `#E8EAE5` | Text/icons on accent surfaces    |

#### Sentiment colours

| Token                | Light     | Dark      | Usage                       |
| -------------------- | --------- | --------- | --------------------------- |
| `sentiment.negative` | `#A8200D` | `#FF6B5A` | Errors, destructive actions |
| `sentiment.positive` | `#2F5711` | `#9FE870` | Success states              |
| `sentiment.warning`  | `#EDC843` | `#EDC843` | Warning backgrounds only    |

### 2.2 Typography

Font: **System default** (San Francisco on iOS, Roboto on Android — matches Inter's clean style).

| Style              | Size | Weight          | Line Height | Letter Spacing | Usage                         |
| ------------------ | ---- | --------------- | ----------- | -------------- | ----------------------------- |
| Title Screen       | 30sp | SemiBold (w600) | 34px        | -2.5%          | Main screen titles            |
| Title Section      | 26sp | SemiBold (w600) | 32px        | -1.5%          | Section headings              |
| Title Subsection   | 22sp | SemiBold (w600) | 28px        | -1.5%          | Sub-section headings          |
| Title Body         | 18sp | SemiBold (w600) | 24px        | -1%            | Card titles, list item titles |
| Body Large         | 16sp | Regular (w400)  | 24px        | -0.5%          | Paragraphs, descriptions      |
| Body Default       | 14sp | Regular (w400)  | 22px        | +1%            | Secondary text, metadata      |
| Body Bold          | 14sp | SemiBold (w600) | 22px        | +1.25%         | Buttons, links, emphasis      |
| Label              | 12sp | Medium (w500)   | 16px        | 0.5%           | Chips, badges, captions       |

#### Reader typography (separate context)

| Style                 | Size | Weight   | Line Height  | Usage                |
| --------------------- | ---- | -------- | ------------ | -------------------- |
| Chapter Title         | 24sp | SemiBold | 32px         | Chapter heading      |
| Reading Body          | 18sp | Regular  | 32px (1.78×) | Main reading content |
| Reading Image Caption | 14sp | Regular  | 20px         | Image alt text       |

### 2.3 Spacing scale

Based on 8px grid (Wise uses 8/16/24/32).

| Token          | Value | Usage                                             |
| -------------- | ----- | ------------------------------------------------- |
| `space.xs`     | 4px   | Tight gaps (icon-to-text in chips)                |
| `space.sm`     | 8px   | Compact spacing (between chips)                   |
| `space.md-sm`  | 12px  | Between cards (Wise `between-cards`)              |
| `space.md`     | 16px  | Standard padding (between sections, components)   |
| `space.lg`     | 24px  | Screen-edge padding, section gaps, sheet padding  |
| `space.xl`     | 32px  | Large section separators                          |
| `space.2xl`    | 48px  | Empty state vertical spacing                      |

### 2.4 Radius scale

Wise mobile scale adapted:

| Token       | Value | Usage                         |
| ----------- | ----- | ----------------------------- |
| `radius.sm` | 10px  | Small chips, badges           |
| `radius.md` | 16px  | Cards, search bars, buttons   |
| `radius.lg` | 24px  | Bottom sheets, dialogs        |
| `radius.xl` | 32px  | Large cards, image containers |

---

## 3. Component specifications

### 3.1 Bottom navigation bar

- **Style**: Flat, no top border, no elevation
- **Background**: `background.screen` (blends with page)
- **Height**: 64px
- **Items**: Icon + label, vertically stacked
- **Active**: `interactive.primary` colour, icon filled
- **Inactive**: `content.tertiary` colour, icon outlined
- **Indicator**: Pill-shaped background behind active icon using `background.neutral`
- **Tabs**: Bookshelf · Feeds · Settings

### 3.2 Search bar

- **Style**: Borderless, filled background
- **Background**: `background.neutral`
- **Radius**: `radius.md` (16px)
- **Height**: 48px
- **Padding**: 16px horizontal
- **Icon**: `content.tertiary` colour, 20px
- **Hint text**: `content.tertiary`
- **Elevation**: 0 (flat)

### 3.3 Buttons

#### Primary button
- **Background**: `interactive.accent` (Bright Green)
- **Text**: `interactive.control` (Forest Green), SemiBold
- **Shape**: Pill / Stadium (fully rounded ends)
- **Height**: 48px (large), 40px (medium), 32px (small)
- **Full width** on mobile for primary actions

#### Secondary button
- **Background**: `background.neutral`
- **Text**: `content.primary`, SemiBold
- **Shape**: Pill / Stadium (fully rounded ends)

#### Tertiary / text button
- **Background**: transparent
- **Text**: `content.link`, SemiBold
- **Shape**: Pill / Stadium (fully rounded ends)

### 3.4 Cards

- **Background**: `background.neutral`
- **Radius**: `radius.md` (16px)
- **Padding**: 16px
- **Elevation**: 0 (no shadow)
- **Border**: none

### 3.5 List items

- **Style**: No dividers between items. Use vertical spacing (8px gap).
- **Background**: transparent (on screen background)
- **Tap feedback**: Subtle `background.neutral` highlight
- **Leading**: 40×56px book cover (radius.sm) or 40px circle avatar
- **Content**: Title (Body Bold) + Subtitle (Body Default, `content.secondary`)
- **Trailing**: Chevron icon or action icon

### 3.6 Chips / tags

- **Background**: `background.neutral`
- **Selected background**: `interactive.primary`
- **Text**: `content.primary` / `Base.contrast` when selected
- **Radius**: `radius.sm` (10px)
- **Height**: 32px
- **Padding**: 12px horizontal

### 3.7 Bottom sheets

- **Background**: `background.elevated`
- **Radius**: `radius.lg` (24px) top corners
- **Drag handle**: 32×4px, `content.tertiary`, centered, radius 2px
- **Padding**: 24px horizontal, 16px top (below handle), 32px bottom

### 3.8 Dialogs

- **Background**: `background.elevated`
- **Radius**: `radius.lg` (24px)
- **Padding**: 24px
- **Elevation**: 0 (use scrim overlay instead)

### 3.9 Snackbars

- **Background**: `content.primary` (dark on light, light on dark)
- **Text**: `background.screen`
- **Radius**: `radius.md` (16px)
- **Margin**: 16px from edges, 16px from bottom nav
- **Action**: `interactive.accent` colour text

---

## 4. Screen designs

### 4.1 Bookshelf (home tab)

**Purpose**: User's saved/bookmarked books library.

**Layout**:
```
┌─────────────────────────────┐
│  Bookshelf          [title] │  ← Large title, left-aligned, no AppBar
│                             │
│  ┌─────────────────────┐    │
│  │ 🔍 Search books…    │    │  ← Tappable search bar → navigates to search
│  └─────────────────────┘    │
│                             │
│  ┌──────┐ ┌──────┐ ┌────┐  │
│  │ cover│ │ cover│ │ ...│  │  ← Grid of book covers (3 columns)
│  │      │ │      │ │    │  │
│  │ Title│ │ Title│ │    │  │
│  │Author│ │Author│ │    │  │
│  └──────┘ └──────┘ └────┘  │
│                             │
│  ┌──────┐ ┌──────┐ ┌────┐  │
│  │      │ │      │ │    │  │
│  └──────┘ └──────┘ └────┘  │
└─────────────────────────────┘
```

**Empty State**:
- Centered illustration area (book icon, 80px, `content.tertiary` at 40% opacity)
- Title: "Your bookshelf is empty" (Title Section)
- Subtitle: "Search and save books to see them here" (Body Large, `content.secondary`)

**Key Design Decisions**:
- No AppBar — use a large left-aligned title with SafeArea padding
- Search bar sits below the title, full width with 16px horizontal margin
- Book grid: 3 columns, cover aspect ratio 3:4, radius.sm on covers
- Book title below cover: Body Bold, 1 line max
- Author below title: Body Default, `content.secondary`, 1 line max

### 4.2 Search page

**Purpose**: Search books across feed sources.

**Layout**:
```
┌─────────────────────────────┐
│  ← Search                   │  ← Minimal AppBar with back button
│                             │
│  ┌─────────────────────┐    │
│  │ 🔍 Search in Feed…  │    │  ← Active search bar, auto-focused
│  └─────────────────────┘    │
│                             │
│  [Feed A] [Feed B] [Feed C] │  ← Horizontal chip row (feed selector)
│                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━  │  ← Thin progress bar (when loading)
│                             │
│  ┌─────────────────────────┐│
│  │ 📖 Book Title           ││  ← Search result card
│  │ Author · Description    ││
│  └─────────────────────────┘│
│                             │
│  ┌─────────────────────────┐│
│  │ 📖 Book Title           ││
│  │ Author · Description    ││
│  └─────────────────────────┘│
└─────────────────────────────┘
```

**Key Design Decisions**:
- Search bar: filled `background.neutral`, no border
- Feed chips: horizontal scroll, selected chip uses `interactive.primary` bg
- Results: Card-style items with `background.neutral` bg, 16px radius, 8px gap between
- Book cover: 48×64px, radius.sm, left side of card
- No dividers — use card spacing

### 4.3 Feeds page

**Purpose**: Manage book source scripts.

**Layout**:
```
┌─────────────────────────────┐
│  Feeds                      │  ← Large title, left-aligned
│                             │
│  ┌─────────────────────┐    │
│  │ 🔍 Search feeds…    │    │  ← Filter search bar
│  └─────────────────────┘    │
│                             │
│  ┌─────────────────────────┐│
│  │ ◇ Feed Name  Enabled › ││  ← Read-only configuration summary
│  │     v1.0 · Author      ││
│  │                         ││
│  └─────────────────────────┘│
│                             │
│  ┌─────────────────────────┐│
│  │ ◇ Feed Name   Paused › ││
│  │     v2.1 · Author       ││
│  └─────────────────────────┘│
│                             │
│              ┌──────┐       │
│              │  +   │       │  ← FAB: Add feed
│              └──────┘       │
└─────────────────────────────┘
```

**Key Design Decisions**:
- No AppBar — large left-aligned title
- Feed items: Card style with `background.neutral`, 16px radius
- Feed icons retain the source initial in a 40px circle, with a subtle tonal
  gradient and fine outline. Paused sources use neutral tones; load errors use
  error tones. The detail sheet uses the same avatar at a larger size.
- Feeds and Transformers share the same summary card: leading icon, title,
  two-line summary, status label, and detail chevron. Feed authentication status
  appears in the summary; load errors use the error colour for the status label.
- Feed and Transformer list rows support swipe-to-delete with confirmation and
  undo. Deleting an inherited application Transformer warns that other books
  are affected. Sorting is disabled while a deletion is pending. The swipe
  background and card share one rounded outline; desktop also exposes a delete
  button. Feed summaries open the detail sheet for enabled state,
  authentication, metadata, and the same delete flow.
- Individual Transformer settings also open in a bottom sheet. The form scrolls
  above fixed Save/Delete actions and clears the keyboard inset. Closing without
  saving discards edits; sorting stays in the Transformer list.
- FAB: `interactive.accent` bg, `interactive.control` icon, **circular** shape

### 4.4 Add feed flow

**Layer 1 — Source Picker (Bottom Sheet)**:
- Borderless list of tappable options (no card background):
  - "From URL" with link icon + description subtitle
  - "From File" with folder icon + description subtitle
- Each option: icon + title (Body Bold) + subtitle (Body Default, `content.secondary`)
- No background fill, no border — separated by vertical spacing
- Chevron trailing icon

**Layer 2 — URL Input / Preview (Dialog)**:
- Clean dialog with 24px radius
- URL input: filled style, `background.neutral`
- Preview card: Shows feed metadata in structured layout
- Install button: Primary (Bright Green), full width

### 4.5 Settings page

**Purpose**: App settings and preferences.

**Layout**:
```
┌─────────────────────────────┐
│  Settings                   │  ← Large title, left-aligned
│                             │
│  READING                    │  ← Section label (Label style, uppercase)
│  ┌─────────────────────────┐│
│  │ Font Size          16sp ││  ← Setting row
│  │ Line Height        1.8× ││
│  │ Theme         System ▸  ││
│  └─────────────────────────┘│
│                             │
│  ABOUT                      │
│  ┌─────────────────────────┐│
│  │ Version           1.0.0 ││
│  │ Licenses              ▸ ││
│  └─────────────────────────┘│
└─────────────────────────────┘
```

**Key Design Decisions**:
- Grouped settings in cards with `background.neutral`
- Section labels: Label style, `content.tertiary`, uppercase
- Setting rows: No dividers, use 1px `background.overlay` separator inside card
- Navigation rows: Chevron trailing icon

### 4.6 Book detail page

```
┌─────────────────────────────┐
│  ←                          │  ← Transparent AppBar over cover
│                             │
│  ┌─────────────────────────┐│
│  │     [Book Cover]        ││  ← Large cover, centered, 120×160px
│  └─────────────────────────┘│
│                             │
│  Book Title                 │  ← Title Section style
│  Author Name                │  ← Body Large, content.secondary
│  Description paragraph...   │  ← Body Default, content.secondary
│                             │
│  ┌─────────────────────────┐│
│  │ Start Reading           ││  ← Primary button, full width
│  └─────────────────────────┘│
│                             │
│  Chapters (42)              │  ← Title Body
│  ┌─────────────────────────┐│
│  │ 1. Chapter Title        ││
│  │ 2. Chapter Title        ││
│  │ 3. Chapter Title        ││
│  └─────────────────────────┘│
└─────────────────────────────┘
```

### 4.7 Reader page

```
┌─────────────────────────────┐
│                             │  ← Full screen, tap to show/hide controls
│  Chapter Title              │  ← Chapter Title style, centered
│                             │
│  Paragraph text flows here  │  ← Reading Body style
│  with generous line height  │
│  for comfortable reading.   │
│                             │
│  [Image]                    │  ← Full width, radius.md
│  Caption text               │  ← Reading Image Caption
│                             │
│  More paragraph text...     │
│                             │
├─────────────────────────────┤
│  ← Prev    Ch.3/42   Next →│  ← Bottom control bar (shown on tap)
└─────────────────────────────┘
```

---

#### Reader surfaces and long titles

The reading surface extends behind transparent system bars. Navigation-bar
contrast enforcement is disabled on the reader so Android does not add a
separate shaded strip. Status and navigation icons follow reader-theme
brightness. A reader-specific theme takes precedence over the application theme.

Toolbar chapter titles occupy one line with ellipsis; a tooltip exposes the full
title. Both chapter directories allow two lines. Chapter headings inside the
content wrap naturally. Horizontal pagination keeps an ordinary heading together
and splits a heading taller than a page without dropping its text or changing
its paragraph identity.

Both chapter directories use `ChapterScrollbar`. The thumb is 12 logical pixels
wide and at least 64 pixels long, with Flutter's minimum 48-pixel touch hit area.
It appears on scrolling, remains available for 1.4 seconds after scrolling ends,
and then fades. Thumb dragging moves through the full directory; it is not an
extra navigation button.

The reader exposes chapter comments at each chapter's end and paragraph
comments where source IDs exist; one reader-level comment switch controls both
surfaces together. Reply threads and sorting open in the comments panel. Use
the same theme surfaces and text contrast for these panels. Listening
highlights the active paragraph; manual reading interactions pause playback.
See
[Search, comments, and listening](search-comments-listening.md) for lifecycle and
progress rules.

## 5. Interaction & motion

### 5.1 Transitions

| Transition   | Duration | Curve            | Usage                 |
| ------------ | -------- | ---------------- | --------------------- |
| Page push    | 300ms    | `easeInOutCubic` | Screen navigation     |
| Bottom sheet | 250ms    | `easeOutCubic`   | Sheet open/close      |
| Fade switch  | 200ms    | `easeInOut`      | Content state changes |
| Chip select  | 150ms    | `easeOut`        | Chip colour change    |

### 5.2 Loading states

- **Skeleton shimmer**: Use `background.overlay` animated over `background.neutral`
- **Progress bar**: Thin (2px) `interactive.accent` linear progress
- **Spinner**: 24px, `interactive.primary` colour, 2px stroke

### 5.3 Empty states

- Icon: 48–56px, `content.tertiary` at 40% opacity, **no background container** (bare icon)
- Title: Title Body style
- Subtitle: Body Large, `content.secondary`
- Optional action button below

### 5.4 Error states

- Icon: 48px, `sentiment.negative` at 60% opacity, **no background container** (bare icon)
- Title: Body Bold, `sentiment.negative`
- Message: Body Default, `content.secondary`
- Retry button: Secondary style

---

## 6. Flutter implementation notes

### 6.1 Themedata mapping

```dart
// Seed colour approach — use Forest Green as seed
ColorScheme.fromSeed(
  seedColor: Color(0xFF163300), // Forest Green
  brightness: Brightness.light,
)
```

Override specific slots:
- `colorScheme.primary` → Forest Green
- `colorScheme.primaryContainer` → Bright Green (accent)
- `colorScheme.surface` → White
- `colorScheme.surfaceContainerHighest` → Neutral bg

### 6.2 Component theme overrides

```dart
// SearchBar
SearchBarThemeData(
  elevation: WidgetStatePropertyAll(0),
  backgroundColor: WidgetStatePropertyAll(neutralBg),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  )),
)

// NavigationBar
NavigationBarThemeData(
  elevation: 0,
  indicatorShape: StadiumBorder(),
  backgroundColor: Colors.transparent,
)

// Card
CardThemeData(
  elevation: 0,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  ),
)

// FilledButton (Primary)
FilledButtonThemeData(
  style: ButtonStyle(
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    )),
  ),
)
```

### 6.3 Key widgets

| Component    | Flutter Widget                                                   |
| ------------ | ---------------------------------------------------------------- |
| Bottom Nav   | `NavigationBar` with custom theme                                |
| Search Bar   | `SearchBar` with filled theme                                    |
| Book Grid    | `SliverGrid` with `SliverGridDelegateWithFixedCrossAxisCount(3)` |
| Feed List    | `ListView` with card-wrapped items                               |
| Chips        | `ChoiceChip` with custom theme                                   |
| Bottom Sheet | `showModalBottomSheet` with custom shape                         |
| Settings     | `ListView` with grouped `Card` sections                          |

---

## 7. Dark mode

All colours have dark mode variants defined in Section 2.1. Key principles:
- Background inverts to near-black with green tint (`#121511`)
- Content colours lighten
- Accent green stays vibrant
- Interactive primary swaps (Forest Green ↔ Bright Green)
- Cards use slightly lighter dark surface

---

## 8. Accessibility

- All text meets WCAG AA contrast (4.5:1 for body, 3:1 for large text)
- Touch targets minimum 48×48px
- Semantic labels on all interactive elements
- Support system font scaling
- Buttons grow height to accommodate larger text
- No colour-only indicators — always pair with icon or text
