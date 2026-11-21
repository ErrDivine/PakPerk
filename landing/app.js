/* Motion for the Pakperk product page.
 *
 * Rules this file keeps to:
 *  - only `transform` and `opacity` are animated;
 *  - `prefers-reduced-motion: reduce` turns every effect off and shows the
 *    page in its final state;
 *  - without JavaScript nothing is hidden, because the `.reveal` start state
 *    lives behind the `.js` class this script adds;
 *  - looping animations pause while they are off-screen.
 */
(() => {
  "use strict";

  const root = document.documentElement;
  root.classList.add("js");

  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  const supported = "IntersectionObserver" in window;

  const showAll = () => {
    document.querySelectorAll(".reveal").forEach((el) => el.classList.add("is-in"));
  };

  /* ---------- reveal on scroll ---------- */

  if (reduced.matches || !supported) {
    showAll();
  } else {
    const revealer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("is-in");
          revealer.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -6% 0px", threshold: 0.06 }
    );
    document.querySelectorAll(".reveal").forEach((el) => revealer.observe(el));

    // A late switch to "reduce" should not leave anything stuck mid-flight.
    reduced.addEventListener?.("change", (e) => {
      if (e.matches) showAll();
    });
  }

  /* ---------- top bar gains a hairline once the hero scrolls away ---------- */

  const topbar = document.querySelector(".topbar");
  if (topbar && supported) {
    const sentinel = document.createElement("div");
    sentinel.setAttribute("aria-hidden", "true");
    sentinel.style.cssText = "position:absolute;top:0;left:0;width:1px;height:1px";
    document.body.prepend(sentinel);
    new IntersectionObserver(
      ([entry]) => topbar.classList.toggle("is-stuck", !entry.isIntersecting)
    ).observe(sentinel);
  }

  /* ---------- looping hints pause while off-screen ---------- */

  const loops = document.querySelectorAll(".bob");
  if (loops.length && supported) {
    const pauser = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        entry.target.classList.toggle("is-paused", !entry.isIntersecting);
      }
    });
    loops.forEach((el) => pauser.observe(el));
  }

  /* ---------- the three stage cards take turns being highlighted ---------- */

  const cycle = document.querySelector(".stagecycle");
  if (cycle && !reduced.matches && supported) {
    const cards = [...cycle.querySelectorAll(".card")];
    if (cards.length > 1) {
      let index = 0;
      let timer = null;
      let onScreen = false;
      let held = false;

      const paint = () => {
        cards.forEach((card, i) => card.classList.toggle("is-lit", i === index));
      };
      const tick = () => {
        index = (index + 1) % cards.length;
        paint();
      };
      const sync = () => {
        const shouldRun = onScreen && !held;
        if (shouldRun && timer === null) {
          timer = window.setInterval(tick, 2600);
        } else if (!shouldRun && timer !== null) {
          window.clearInterval(timer);
          timer = null;
        }
      };

      paint();
      new IntersectionObserver(
        ([entry]) => {
          onScreen = entry.isIntersecting;
          sync();
        },
        { threshold: 0.25 }
      ).observe(cycle);

      // Reading one card should not be interrupted by the highlight moving on.
      const hold = (on) => () => {
        held = on;
        sync();
      };
      cycle.addEventListener("pointerenter", hold(true));
      cycle.addEventListener("pointerleave", hold(false));
      cycle.addEventListener("focusin", hold(true));
      cycle.addEventListener("focusout", hold(false));

      reduced.addEventListener?.("change", (e) => {
        if (!e.matches) return;
        held = true;
        sync();
        cards.forEach((card) => card.classList.remove("is-lit"));
      });
    }
  }
})();
