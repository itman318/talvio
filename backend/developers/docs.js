// fills in this server's address everywhere the examples show it
(function () {
  var base = location.origin;
  document.querySelectorAll('.base').forEach(function (el) { el.textContent = base; });
}());
