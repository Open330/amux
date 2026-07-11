document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const command = button.parentElement?.querySelector("code")?.textContent;
    if (!command) return;

    await navigator.clipboard.writeText(command.trim());
    const previous = button.textContent;
    button.textContent = "OK";
    window.setTimeout(() => {
      button.textContent = previous;
    }, 1200);
  });
});

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = String(new Date().getFullYear());
});
