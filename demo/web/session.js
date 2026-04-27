document.addEventListener("DOMContentLoaded", () => {

  /* =============================
     Session & Client Info
     ============================= */
  fetch("/headers")
    .then(res => res.json())
    .then(data => {
      const clientIp = document.getElementById("client-ip");
      const xff = document.getElementById("xff");
      const webServer = document.getElementById("web-server");

      if (clientIp) clientIp.innerText = data.client_ip || "N/A";
      if (xff) xff.innerText = data.x_forwarded_for || "N/A";
      if (webServer) webServer.innerText = data.web_server || "N/A";
    })
    .catch(() => {});

  /* =============================
     Dark Mode Toggle
     ============================= */
  const toggle = document.getElementById("theme-toggle");
  const savedTheme = localStorage.getItem("theme");

  if (savedTheme === "dark") {
    document.body.classList.add("dark");
    if (toggle) toggle.checked = true;
  }

  if (toggle) {
    toggle.addEventListener("change", () => {
      document.body.classList.toggle("dark", toggle.checked);
      localStorage.setItem("theme", toggle.checked ? "dark" : "light");
    });
  }

  /* =============================
     Scroll Reveal Animations
     ============================= */
  const reveals = document.querySelectorAll(".reveal");
  const observer = new IntersectionObserver(
    entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add("visible");
        }
      });
    },
    { threshold: 0.15 }
  );

  reveals.forEach(el => observer.observe(el));

  /* =============================
     KPI Metrics (Avi-style demo)
     ============================= */
  const setValue = (id, value) => {
    const el = document.getElementById(id);
    if (el) el.innerText = value;
  };

  setValue("kpi-e2e", (Math.random() * 3 + 1).toFixed(1));
  setValue("kpi-throughput", (Math.random() * 250 + 6).toFixed(1));
  setValue("kpi-openconns", Math.floor(Math.random() * 5 + 3));
  setValue("kpi-newconns", (Math.random() * 1.5).toFixed(1));
  setValue("kpi-requests", (Math.random() * 2 + 0.5).toFixed(1));
  setValue("kpi-est-cap", "0.0");
  setValue("kpi-avail-cap", "0.0");
});

/* =============================
   Force New Connection + Refresh
   ============================= */
const newConnBtn = document.getElementById("new-conn-btn");
const rrIframe = document.getElementById("rr-iframe");

if (newConnBtn && rrIframe) {
  newConnBtn.addEventListener("click", () => {
    rrIframe.src = `/new-connection?ts=${Date.now()}`;
    setTimeout(() => window.location.reload(), 200);
  });
}

/* =============================
   Architecture Slideshow
   ============================= */
(() => {
  const slides = document.querySelectorAll(".slide");
  const dotsContainer = document.querySelector(".slide-dots");
  const prev = document.querySelector(".slide-nav.prev");
  const next = document.querySelector(".slide-nav.next");

  if (!slides.length || !dotsContainer) return;

  let index = 0;
  dotsContainer.innerHTML = "";

  slides.forEach((_, i) => {
    const dot = document.createElement("button");
    dot.className = `dot${i === 0 ? " active" : ""}`;
    dot.addEventListener("click", () => showSlide(i));
    dotsContainer.appendChild(dot);
  });

  const dots = dotsContainer.querySelectorAll(".dot");

  function showSlide(i) {
    slides.forEach(s => s.classList.remove("active"));
    dots.forEach(d => d.classList.remove("active"));
    slides[i].classList.add("active");
    dots[i].classList.add("active");
    index = i;
  }

  prev?.addEventListener("click", () =>
    showSlide((index - 1 + slides.length) % slides.length)
  );

  next?.addEventListener("click", () =>
    showSlide((index + 1) % slides.length)
  );
})();

/* =============================
   WAF Attack Simulation
   ============================= */

const wafBtn = document.getElementById("waf-attack-btn");
const wafIndicator = document.getElementById("waf-indicator");

function setWAFState(blocked) {
  if (!wafIndicator) return;

  if (blocked) {
    wafIndicator.classList.remove("waf-safe");
    wafIndicator.classList.add("waf-blocked");
    wafIndicator.querySelector(".kpi-value").innerHTML =
      '<span class="dot"></span> Exploit Blocked';
  } else {
    wafIndicator.classList.remove("waf-blocked");
    wafIndicator.classList.add("waf-safe");
    wafIndicator.querySelector(".kpi-value").innerHTML =
      '<span class="dot"></span> Normal';
  }
}

if (wafBtn) {
  wafBtn.addEventListener("click", () => {
    fetch("/index.html?q=<script>alert(1)</script>", {
      cache: "no-store"
    })
      .then(res => {
        if (!res.ok) throw new Error("Blocked");
        setWAFState(false);
      })
      .catch(() => {
        // Expected path when Avi WAF blocks the request
        setWAFState(true);
      });
  });
}

