// Shared breakpoints for every Forkop page. CSS media queries cannot read
// custom properties, so pages use these numbers directly:
//   wide   >= 1280px
//   medium  900-1279px (1024 layouts)
//   narrow  600-899px  (768 layouts)
//   phone   < 600px
export const BREAKPOINTS = {
  medium: 1279,
  narrow: 899,
  phone: 599,
} as const;

// language=CSS
export const styles = `
:root {
    --fkp-space-1: 4px;
    --fkp-space-2: 8px;
    --fkp-space-3: 12px;
    --fkp-space-4: 16px;
    --fkp-space-5: 24px;
    --fkp-tone-success: var(--success-color-medium, #2e7d32);
    --fkp-tone-warning: var(--warn-color-medium, #b26a00);
    --fkp-tone-error: var(--error-color-medium, #c62828);
    --fkp-tone-loading: var(--primary-color-high, #1565c0);
    --fkp-tone-neutral: var(--text-color-medium, #616161);
    --fkp-tone-muted: var(--text-color-low, #9e9e9e);
    --fkp-border: var(--border-color-medium, rgba(127, 127, 127, 0.35));
}

.fkp-status {
    display: inline-block;
    max-width: 100%;
    box-sizing: border-box;
    padding: 1px var(--fkp-space-2);
    border: 1px solid currentColor;
    border-radius: 999px;
    font-size: 0.9em;
    line-height: 1.5;
    white-space: normal;
    overflow-wrap: anywhere;
}
.fkp-status--success { color: var(--fkp-tone-success); }
.fkp-status--warning { color: var(--fkp-tone-warning); }
.fkp-status--error { color: var(--fkp-tone-error); }
.fkp-status--loading { color: var(--fkp-tone-loading); }
.fkp-status--neutral { color: var(--fkp-tone-neutral); }
.fkp-status--muted { color: var(--fkp-tone-muted); }

.fkp-provenance {
    display: inline-block;
    padding: 0 var(--fkp-space-1);
    border: 1px dashed var(--fkp-border);
    border-radius: 4px;
    font-size: 0.8em;
    color: var(--fkp-tone-neutral);
    white-space: normal;
}

.fkp-state {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: var(--fkp-space-2);
    padding: var(--fkp-space-3) 0;
    min-width: 0;
}
.fkp-state__title { font-weight: 600; overflow-wrap: anywhere; }
.fkp-state__hint { color: var(--fkp-tone-neutral); overflow-wrap: anywhere; }
.fkp-state--error .fkp-state__title { color: var(--fkp-tone-error); }
.fkp-state--loading .fkp-state__title { color: var(--fkp-tone-loading); font-weight: normal; }

.fkp-tech { margin-top: var(--fkp-space-2); max-width: 100%; }
.fkp-tech > summary { cursor: pointer; color: var(--fkp-tone-neutral); }
.fkp-tech__content {
    max-height: 320px;
    overflow: auto;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    font-size: 0.85em;
}

.fkp-confirm__consequences { margin: var(--fkp-space-2) 0 var(--fkp-space-3) var(--fkp-space-5); }
.fkp-confirm__actions {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: var(--fkp-space-2);
}

.fkp-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--fkp-space-2);
    min-width: 0;
}
.fkp-action-danger-text {
    color: var(--fkp-tone-error) !important;
}
`;
