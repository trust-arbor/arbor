const csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute('content');
const Hooks = {Composer: {mounted() {
  const clear = () => {
    this.el.reset();
    this.el.querySelector('input[name="text"]').value = '';
  };
  this.handleEvent('composer:sent', event => {
    const input = this.el.querySelector('input[name="text"]');
    if (!Object.prototype.hasOwnProperty.call(event, 'text') || input.value === event.text) clear();
  });
  this.handleEvent('composer:clear', clear);
}}};
const liveSocket = new window.LiveView.LiveSocket('/live', window.Phoenix.Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks});
liveSocket.connect();
window.liveSocket = liveSocket;
