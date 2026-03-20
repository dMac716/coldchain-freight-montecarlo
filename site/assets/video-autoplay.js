// Autoplay videos when they enter viewport, pause when they leave, loop always
document.addEventListener('DOMContentLoaded', function() {
  const videos = document.querySelectorAll('video');
  if (!videos.length) return;

  videos.forEach(function(v) {
    v.loop = true;
    v.muted = true;
    v.playsInline = true;
  });

  const observer = new IntersectionObserver(function(entries) {
    entries.forEach(function(entry) {
      if (entry.isIntersecting) {
        entry.target.play().catch(function() {});
      } else {
        entry.target.pause();
      }
    });
  }, { threshold: 0.3 });

  videos.forEach(function(v) { observer.observe(v); });
});
