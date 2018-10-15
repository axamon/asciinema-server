defmodule AsciinemaWeb.AsciicastController do
  use AsciinemaWeb, :controller
  alias Asciinema.{Asciicasts, PngGenerator}
  alias Asciinema.Asciicasts.Asciicast

  plug :put_layout, "app2.html"
  plug :clear_main_class
  plug :load_asciicast when action in [:show, :edit, :update, :delete]
  plug :require_current_user when action in [:edit, :update, :delete]
  plug :authorize, :asciicast when action in [:edit, :update, :delete]

  def index(conn, _params) do
    redirect(conn, to: asciicast_path(conn, :category, :featured))
  end

  def category(conn, %{"category" => c} = params) when c in ["featured", "public"] do
    category = String.to_existing_atom(c)
    order = if params["order"] == "popularity", do: :popularity, else: :date

    page =
      category
      |> Asciicasts.category_asciicasts()
      |> Asciicasts.paginate_asciicasts(order, params["page"], 12)

    assigns = [
      page_title: String.capitalize("#{category} asciicasts"),
      category: category,
      page: page,
      order: order
    ]

    render(conn, "category.html", assigns)
  end

  def category(conn, _params) do
    redirect(conn, to: asciicast_path(conn, :category, :featured))
  end

  def show(conn, _params) do
    do_show(conn, get_format(conn), conn.assigns.asciicast)
  end

  def do_show(conn, "html", asciicast) do
    opts = Asciicasts.PlaybackOpts.parse(conn.params)

    conn
    |> count_view(asciicast)
    |> render(
      "show.html",
      page_title: AsciinemaWeb.AsciicastView.title(asciicast),
      asciicast: asciicast,
      playback_options: opts,
      author_asciicasts: Asciicasts.other_public_asciicasts(asciicast)
    )
  end

  def do_show(conn, format, asciicast) when format in ["json", "cast"] do
    path = Asciicast.json_store_path(asciicast)
    filename = download_filename(asciicast, conn.params)
    file_store().serve_file(conn, path, filename)
  end

  @js_max_age 60

  def do_show(conn, "js", _asciicast) do
    path = Application.app_dir(:asciinema, "priv/static/js/embed.js")

    conn
    |> put_resp_content_type("application/javascript")
    |> put_resp_header("cache-control", "public, max-age=#{@js_max_age}")
    |> send_file(200, path)
  end

  @png_max_age 604_800 # 7 days

  def do_show(conn, "png", asciicast) do
    user = Repo.preload(asciicast, :user).user
    png_params = Asciicast.png_params(asciicast, user)

    case PngGenerator.generate(asciicast, png_params) do
      {:ok, png_path} ->
        conn
        |> put_resp_header("content-type", MIME.from_path(png_path))
        |> put_resp_header("cache-control", "public, max-age=#{@png_max_age}")
        |> send_file(200, png_path)
        |> halt

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "5")
        |> send_resp(503, "")
    end
  end

  def do_show(conn, "gif", asciicast) do
    conn
    |> put_layout("simple.html")
    |> render("gif.html", file_url: asciicast_file_url(conn, asciicast))
  end

  def edit(conn, _params) do
    changeset = Asciicasts.change_asciicast(conn.assigns.asciicast)
    render(conn, "edit.html", changeset: changeset)
  end

  def update(conn, %{"asciicast" => asciicast_params}) do
    asciicast = conn.assigns.asciicast

    case Asciicasts.update_asciicast(asciicast, asciicast_params) do
      {:ok, asciicast} ->
        conn
        |> put_flash(:info, "Asciicast updated.")
        |> redirect(to: asciicast_path(conn, :show, asciicast))

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", changeset: changeset)
    end
  end

  def delete(conn, _params) do
    asciicast = conn.assigns.asciicast

    case Asciicasts.delete_asciicast(asciicast) do
      {:ok, _asciicast} ->
        conn
        |> put_flash(:info, "Asciicast deleted.")
        |> redirect(to: profile_path(conn, conn.assigns.current_user))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Oops, couldn't remove this asciicast.")
        |> redirect(to: asciicast_path(conn, :show, asciicast))
    end
  end

  def iframe(conn, %{"id" => id}) do
    asciicast = Asciicasts.get_asciicast!(id)

    conn
    |> put_layout("iframe.html")
    |> delete_resp_header("x-frame-options")
    |> render("iframe.html", file_url: asciicast_file_url(conn, asciicast))
  end

  def embed(conn, %{"id" => id} = params) do
    asciicast = Asciicasts.get_asciicast!(id)
    opts = Asciicasts.PlaybackOpts.parse(params)

    conn
    |> put_layout("embed.html")
    |> delete_resp_header("x-frame-options")
    |> render("embed.html",
      asciicast: asciicast,
      playback_options: opts
    )
  end

  def example(conn, %{"id" => id}) do
    asciicast = Asciicasts.get_asciicast!(id)
    home_asciicast = Asciicasts.get_homepage_asciicast()

    conn
    |> put_layout("example.html")
    |> render("example.html", asciicast: asciicast, home_asciicast: home_asciicast)
  end

  defp download_filename(%Asciicast{version: version, id: id}, %{"dl" => _}) do
    case version do
      0 -> "#{id}.json"
      1 -> "#{id}.json"
      2 -> "#{id}.cast"
    end
  end

  defp download_filename(_asciicast, _params) do
    nil
  end

  defp file_store do
    Application.get_env(:asciinema, :file_store)
  end

  defp load_asciicast(conn, _) do
    assign(conn, :asciicast, Asciicasts.get_asciicast!(conn.params["id"]))
  end

  defp count_view(conn, asciicast) do
    key = "a#{asciicast.id}"

    case conn.req_cookies[key] do
      nil ->
        Asciicasts.inc_views_count(asciicast)
        put_resp_cookie(conn, key, "1", max_age: 3600*24)

      _ ->
        conn
    end
  end
end
