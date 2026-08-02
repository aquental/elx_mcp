defmodule ElxMcpWeb.PageController do
  use ElxMcpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
