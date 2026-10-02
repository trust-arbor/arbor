defmodule ConversationDemo.Layout do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Conversation / interface study</title>
        <link rel="icon" href="data:," />
        <link rel="stylesheet" href="/assets/app.css" />
        <script src="/assets/phoenix.js"></script>
        <script src="/assets/phoenix_live_view.js"></script>
        <script defer src="/assets/app.js?v=20260926-2"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end
