defmodule Coordinator.Web.AdminLayoutTest do
  @moduledoc """
  The admin console builds HTML by string interpolation, so `esc/1` is the only thing standing
  between user-controlled text and script execution in an admin's browser. It had no test.

  The values that reach it are worker ids, gateway key labels and GitHub logins — all of them
  chosen by someone other than the admin reading the page.
  """
  use ExUnit.Case, async: true

  import Coordinator.Web.AdminLayout, only: [esc: 1, fmt_dt: 1]

  describe "esc/1" do
    test "neutralises the characters that break out of an HTML context" do
      assert esc("<script>alert(1)</script>") ==
               "&lt;script&gt;alert(1)&lt;/script&gt;"

      # Attribute-breaking quotes matter as much as tags: these values are interpolated into
      # `value="..."` and `action="..."` as well as into element bodies.
      quote_payload = "\" onmouseover=\"alert(1)"
      assert esc(quote_payload) =~ "&quot;"
      refute esc(quote_payload) =~ "\""

      assert esc("a & b") == "a &amp; b"
      assert esc("'") =~ "&#39;"
    end

    test "a worker id that is really a payload cannot close its tag" do
      # Worker ids are machine-derived but arrive over the wire, so the console must not trust
      # their shape.
      escaped = esc("w-1\"><img src=x onerror=alert(1)>")

      refute escaped =~ "<img"
      refute escaped =~ "\""
      assert escaped =~ "w-1"
    end

    test "nil renders as empty rather than the string \"nil\"" do
      assert esc(nil) == ""
    end

    test "non-strings are stringified, then escaped" do
      assert esc(42) == "42"
      assert esc(:public) == "public"
      assert esc(["<b>", "&"]) =~ "&lt;b&gt;"
    end

    test "escaping is not doubled on already-safe text" do
      assert esc("plain text") == "plain text"
      assert esc("") == ""
    end
  end

  describe "fmt_dt/1" do
    test "nil renders as a muted never" do
      assert fmt_dt(nil) =~ "never"
      assert fmt_dt(nil) =~ "muted"
    end

    test "a datetime renders to the minute" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-09-12T21:30:15.123456Z")
      assert fmt_dt(dt) == "2026-09-12 21:30"
    end

    test "anything else is escaped rather than interpolated raw" do
      # The fallback clause routes through `esc/1`; if it did not, an unexpected value would be
      # a hole in the same wall.
      assert fmt_dt("<script>") == "&lt;script&gt;"
    end
  end
end
