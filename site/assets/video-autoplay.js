/**
 * video-autoplay.js
 *
 * Automatically plays <video> elements when they scroll into the viewport
 * and pauses them when they scroll out. Used on the GitHub Pages site for
 * route simulation animations and Monte Carlo evolution videos.
 *
 * Behavior:
 *   - All videos are set to loop, muted, and playsInline on page load.
 *     Muting is required by most browsers for autoplay to work without
 *     user interaction (Chrome, Safari, Firefox all block unmuted autoplay).
 *   - An IntersectionObserver watches each video element. When at least 30%
 *     of the video is visible (threshold: 0.3), playback starts. When it
 *     drops below that threshold, playback pauses. The 0.3 threshold was
 *     chosen to avoid playing videos that are barely peeking into the
 *     viewport (e.g., just a sliver visible during fast scrolling) while
 *     still starting playback before the video is fully centered.
 *   - The .catch(function() {}) on play() suppresses the DOMException that
 *     browsers throw when play() is interrupted by a rapid pause() call
 *     (common during fast scrolling). This is harmless and expected.
 *
 * Dependencies: None (vanilla JS, no libraries).
 * Loaded by: site/*.qmd pages via <script> tag in the HTML header.
 */
document.addEventListener('DOMContentLoaded', function() {
  const videos = document.querySelectorAll('video');
  if (!videos.length) return;

  // Force muted + loop + inline for autoplay policy compliance
  videos.forEach(function(v) {
    v.loop = true;
    v.muted = true;
    v.playsInline = true;
  });

  // Play/pause based on viewport visibility (30% threshold)
  const observer = new IntersectionObserver(function(entries) {
    entries.forEach(function(entry) {
      if (entry.isIntersecting) {
        // Suppress DOMException from play() interrupted by rapid pause()
        entry.target.play().catch(function() {});
      } else {
        entry.target.pause();
      }
    });
  }, { threshold: 0.3 });

  videos.forEach(function(v) { observer.observe(v); });
});
