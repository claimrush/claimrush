module.exports = {
  theme: {
    extend: {
      colors: {
        cr: {
          // Brand
          gold: "rgb(var(--cr-gold) / <alpha-value>)",
          goldDim: "rgb(var(--cr-gold-dim) / <alpha-value>)",
          blue: "rgb(var(--cr-blue) / <alpha-value>)",
          ink: "rgb(var(--cr-ink) / <alpha-value>)",

          // Surfaces
          bg: "rgb(var(--cr-bg) / <alpha-value>)",
          surface: "rgb(var(--cr-surface) / <alpha-value>)",
          surface2: "rgb(var(--cr-surface-2) / <alpha-value>)",
          surface3: "rgb(var(--cr-surface-3) / <alpha-value>)",
          overlay: "rgb(var(--cr-overlay) / <alpha-value>)",

          // Borders
          border: "rgb(var(--cr-border) / <alpha-value>)",
          borderSubtle: "rgb(var(--cr-border-subtle) / <alpha-value>)",
          borderStrong: "rgb(var(--cr-border-strong) / <alpha-value>)",

          // Text
          text: "rgb(var(--cr-text) / <alpha-value>)",
          textSubtle: "rgb(var(--cr-text-subtle) / <alpha-value>)",
          muted: "rgb(var(--cr-text-muted) / <alpha-value>)",

          // Interaction
          primary: "rgb(var(--cr-primary) / <alpha-value>)",
          primaryFg: "rgb(var(--cr-primary-fg) / <alpha-value>)",
          ring: "rgb(var(--cr-ring) / <alpha-value>)",

          // Prestige
          accent: "rgb(var(--cr-accent) / <alpha-value>)",
          accentFg: "rgb(var(--cr-accent-fg) / <alpha-value>)",
          accentDim: "rgb(var(--cr-gold-dim) / <alpha-value>)",

          // States
          success: "rgb(var(--cr-success) / <alpha-value>)",
          warning: "rgb(var(--cr-warning) / <alpha-value>)",
          danger: "rgb(var(--cr-danger) / <alpha-value>)",
        },
      },
      fontFamily: {
        sans: ["var(--font-sans)", "ui-sans-serif", "system-ui"],
        display: ["var(--font-display)", "var(--font-sans)"],
        mono: ["var(--font-mono)", "ui-monospace", "SFMono-Regular"],
      },
    },
  },
};
