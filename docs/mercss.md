# mercss - Compile-time atomic CSS for merjs

mercss is an experimental, small compile-time CSS generator. It turns Zig style
structs into CSS and class-name constants with no runtime allocation or separate
CSS build step.

The framework exports generators, not a component library. Application design
tokens and components belong in application or package code.

## Quick start

```zig
const mer = @import("mer");
const h = mer.h;
const mercss = mer.mercss;

const Theme = struct {
    const primary = "#3b82f6";
};

const Button = mercss.Component(.{
    .background = Theme.primary,
    .color = "white",
    .padding = "12px 24px",
    .border_radius = "8px",
    .font_weight = "600",
});

pub const meta: mer.Meta = .{
    .extra_head = "<style>" ++ Button.css ++ "</style>",
};

pub fn render(req: mer.Request) mer.Response {
    return mer.render(
        req.allocator,
        h.button(.{ .class = Button.classes }, "Click me"),
    );
}
```

`Button.css` and `Button.classes` are compile-time strings. For the example
above they contain one rule and one class per property. Snake-case property
names are converted to CSS kebab-case; integer values are emitted as pixels.

## Responsive components

`ResponsiveComponent` emits mobile-first base rules and media queries for the
present `sm`, `md`, `lg`, and `xl` fields:

```zig
const ResponsiveContainer = mercss.ResponsiveComponent(.{
    .base = .{ .padding = "16px", .font_size = "14px" },
    .sm = .{ .padding = "24px", .font_size = "16px" },
    .md = .{ .padding = "32px", .font_size = "18px" },
    .lg = .{ .padding = "48px" },
});

const css = ResponsiveContainer.css;
const classes = ResponsiveContainer.classes;
```

The breakpoint values are also available as `mercss.Breakpoints.sm`, `.md`,
`.lg`, `.xl`, and `.xl2`. `xl2` is a published token, but
`ResponsiveComponent` currently generates variants only through `xl`.

## Public primitives

- `mercss.Component(styles)` creates a type with `css` and `classes` constants.
- `mercss.ResponsiveComponent(config)` creates the same constants plus
  mobile-first breakpoint rules.
- `mercss.Breakpoints` exposes the standard breakpoint widths.

Styles are ordinary Zig structs, so applications can keep type-safe tokens in
an app-local theme:

```zig
const Theme = struct {
    const colors = .{
        .primary = "#3b82f6",
        .danger = "#ef4444",
    };
    const spacing = .{ .sm = 8, .md = 16, .lg = 24 };
};

const Alert = mercss.Component(.{
    .background = Theme.colors.danger,
    .padding = Theme.spacing.md, // emits 16px
});
```

See `examples/site/app/mercss-demo.zig` for a complete page with app-owned
`DesignSystem`, `Button`, `Card`, `Alert`, and responsive container definitions.

## Deprecated demo compatibility

mercss remains experimental. The old demo declarations — `DesignSystem`,
`Button`, `Card`, `Alert`, `ResponsiveContainer`, `getDemoHtml`, `getAllCss`, and
`exampleUsage` — are no longer imported or re-exported by `mer.mercss`. The core
module contains only the reusable `Component`, `ResponsiveComponent`, and
`Breakpoints` primitives.

Code that needs a short migration window can explicitly use the separate
`mer.mercss_compat` namespace. For example, replace `mer.mercss.Button` with
`mer.mercss_compat.Button` while moving that component into application code.
This deprecated namespace is a demo-only compatibility bridge and will be
removed in **0.3.0**. `Navbar`, `Hero`, and `Badge` are not framework mercss
exports; component libraries or applications should own such UI surfaces.

## Current limits

mercss does not currently generate state variants (`hover`, `focus`, or
`active`), dark-mode variants, container queries, plugins, resets, keyframes,
or an `@apply` equivalent. CSS strings must be included by the application,
usually through `Meta.extra_head`, and each component's CSS should be included
only once.
