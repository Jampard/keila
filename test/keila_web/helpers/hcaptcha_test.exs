# Modified by EklipseTech, 2026; see NOTICE.
defmodule KeilaWeb.CaptchaTest do
  use ExUnit.Case
  import KeilaWeb.Captcha

  @moduletag :network

  @valid_hcaptcha "10000000-aaaa-bbbb-cccc-000000000001"
  @invalid_hcaptcha "00000000-aaaa-bbbb-cccc-000000000001"

  test "validate captchas" do
    assert true == captcha_valid?(@valid_hcaptcha)
    assert false == captcha_valid?(@invalid_hcaptcha)
    assert false == captcha_valid?("")
  end
end
