---
name: Ink & Equity
colors:
  surface: '#fbf9f4'
  surface-dim: '#dbdad5'
  surface-bright: '#fbf9f4'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f5f3ee'
  surface-container: '#f0eee9'
  surface-container-high: '#eae8e3'
  surface-container-highest: '#e4e2dd'
  on-surface: '#1b1c19'
  on-surface-variant: '#58423c'
  inverse-surface: '#30312e'
  inverse-on-surface: '#f2f1ec'
  outline: '#8b716b'
  outline-variant: '#dfc0b8'
  surface-tint: '#a8381c'
  primary: '#9c2f14'
  on-primary: '#ffffff'
  primary-container: '#bd472a'
  on-primary-container: '#ffeeea'
  inverse-primary: '#ffb4a2'
  secondary: '#5d5f60'
  on-secondary: '#ffffff'
  secondary-container: '#dfdfe0'
  on-secondary-container: '#616364'
  tertiary: '#005d7a'
  on-tertiary: '#ffffff'
  tertiary-container: '#00779b'
  on-tertiary-container: '#e3f4ff'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#ffdad2'
  primary-fixed-dim: '#ffb4a2'
  on-primary-fixed: '#3c0700'
  on-primary-fixed-variant: '#872106'
  secondary-fixed: '#e2e2e3'
  secondary-fixed-dim: '#c6c6c7'
  on-secondary-fixed: '#1a1c1d'
  on-secondary-fixed-variant: '#454748'
  tertiary-fixed: '#bfe8ff'
  tertiary-fixed-dim: '#7cd1f9'
  on-tertiary-fixed: '#001f2b'
  on-tertiary-fixed-variant: '#004d65'
  background: '#fbf9f4'
  on-background: '#1b1c19'
  surface-variant: '#e4e2dd'
  bone-surface: '#F9F7F2'
  charcoal-text: '#1A1B1C'
  graphite-metadata: '#5E6266'
  terracotta-accent: '#BD472A'
  market-up: '#2D7A4D'
  market-down: '#C9302C'
typography:
  display-price:
    fontFamily: Inter
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-title:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: -0.01em
  body-main:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 22px
  body-metadata:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 18px
  data-label:
    fontFamily: Inter
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.05em
  data-value-lg:
    fontFamily: Inter
    fontSize: 18px
    fontWeight: '500'
    lineHeight: 24px
  data-value-sm:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 18px
  caption:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: '400'
    lineHeight: 14px
spacing:
  unit: 4px
  margin-edge: 16px
  gutter-dense: 8px
  row-height-sm: 40px
  row-height-md: 56px
  matrix-gap: 2px
---

## Brand & Style
The design system is rooted in Edward Tufte’s "Data-Ink" doctrine, prioritizing the communication of complex financial information over decorative interface elements. It is designed for the serious comic collector who views their collection through the lens of an asset portfolio. The brand personality is scholarly, disciplined, and premium, avoiding the "gamified" or "comic-booky" tropes common in the hobby.

The chosen style is **Minimalism** with a focus on **High-Density Data**. By stripping away "chartjunk"—shadows, gridlines, and borders—the system relies on typographic hierarchy and whitespace to create structure. The interface feels like a high-end financial broadsheet or a bespoke terminal, providing a professional environment for high-stakes valuation and market analysis.

## Colors
This design system utilizes a "monochrome-plus-one" palette to ensure that visual attention is strictly reserved for actionable data and anomalies. 

- **Surface:** A warm `bone` (#F9F7F2) background reduces eye strain and provides an editorial, paper-like quality compared to stark white.
- **Typography:** `charcoal-text` (#1A1B1C) is used for primary data points, while `graphite-metadata` (#5E6266) provides a softer contrast for labels and secondary information.
- **Accents:** A deep `terracotta` (#BD472A) serves as the primary brand touchpoint, used sparingly for interaction affordances and anomalous data spikes.
- **Semantic Data:** Positive and negative price movements are represented by muted `market-up` (Green) and `market-down` (Red). These are desaturated to ensure they remain professional and do not overwhelm the neutral aesthetic.

## Typography
Typography is the primary structural tool of this design system. We use **Inter** for its exceptional legibility and robust OpenType features. 

**Critical Requirement:** All price data, comic grades (e.g., 9.8), and percentage deltas must use **Tabular (tnum)** and **Lining (lnum)** figures. This ensures that columns of numbers align vertically, allowing collectors to scan values and detect magnitude differences instantly without the visual "jitter" of proportional figures.

Headlines use tighter tracking and heavier weights to anchor content blocks, while metadata uses a reduced size and color contrast to recede into the background.

## Layout & Spacing
The layout follows a **Fixed Grid** philosophy adapted for mobile. We use a 4px baseline shift to maintain a tight, "financial-dense" rhythm. 

- **Margins:** Standard 16px side margins for readability.
- **No Borders:** Instead of using lines to separate data, we use "negative space as a divider." Row items are separated by subtle shifts in vertical padding.
- **Alignment:** 
    - Text labels and titles are always **left-aligned**.
    - All numeric data (prices, quantities, grades) must be **right-aligned** to the nearest margin or gutter to facilitate vertical scanning.
- **The Matrix:** For the `GradeTierMatrix`, a extremely dense grid is used with 2px gaps, allowing for a "bird's-eye view" of market availability across all condition grades on a single screen.

## Elevation & Depth
In accordance with the Tufte-inspired doctrine, this design system is **entirely flat**. 

- **No Shadows:** Elevation is never conveyed through drop shadows or glows.
- **Tonal Layers:** Depth is created through subtle background shifts if necessary, but primarily through typography. 
- **The "Surface":** The primary `bone` surface is treated as a continuous sheet. Content is replaced in-situ or through horizontal sliding transitions.
- **Focus:** Selection is indicated through the `terracotta` accent color or a simple high-contrast reversal (e.g., charcoal background with bone text) rather than "lifting" an object off the surface.

## Shapes
To maintain a professional, architectural aesthetic, the design system utilizes **Sharp (0px)** corners for all data containers, matrix cells, and input fields. Softness is viewed as a consumer-oriented distraction. Only the conversational input bar and primary action buttons may use a minimal `2px` radius to subtly indicate interactivity without breaking the rigorous geometric logic of the data-dense layout.

## Components
- **Watchlist Rows:** High-density horizontal layouts. Left side contains the Issue Title (Strong) and Publisher (Small/Muted). Right side contains the Price (Right-aligned/Tabular) and a small sparkline showing 30-day movement. No trailing arrows or borders.
- **Metric Cards:** Simple groupings of a small uppercase label (e.g., "FMV") over a large tabular value. No card container or shadow; defined only by their proximity to each other.
- **Sparklines:** Minimalist vector paths. The line should be `charcoal`, with a single `terracotta` dot marking the most recent data point. No axes or background fills.
- **GradeTierMatrix:** A grid of cells representing grades 0.5 through 10.0. Cell background intensity represents volume; text color changes from charcoal to bone for high-volume (darker) cells.
- **Conversational Input:** A pinned bar at the bottom. Use a simple text underline or a 1px `graphite` border to distinguish the input area. The "send" action is a simple terracotta arrow glyph.
- **Semantic Badges:** For `market-up/down`, use a small directional glyph (▲/▼) immediately preceding the value. Do not wrap in a pill or button shape; let the color and glyph handle the communication.