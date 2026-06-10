// VULNERABLE: untrusted location.hash written to innerHTML → DOM XSS.
export function render(el) { el.innerHTML = decodeURIComponent(location.hash.slice(1)); }
