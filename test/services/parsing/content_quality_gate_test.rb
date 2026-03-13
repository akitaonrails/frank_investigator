require "test_helper"

class Parsing::ContentQualityGateTest < ActiveSupport::TestCase
  test "passes valid article content" do
    body = "The government announced new fiscal measures for 2026. " * 10
    result = Parsing::ContentQualityGate.call(body_text: body)
    assert result.pass
    assert_nil result.reason
  end

  test "fails empty content" do
    result = Parsing::ContentQualityGate.call(body_text: "")
    assert_not result.pass
    assert_equal :empty_shell, result.reason
  end

  test "fails content that is too short" do
    result = Parsing::ContentQualityGate.call(body_text: "Short text here.")
    assert_not result.pass
    assert_equal :too_short, result.reason
  end

  test "fails login page content" do
    body = "Login to your account. Enter your senha. Sign in or cadastre-se. Forgot your password? Entrar agora. " * 3
    result = Parsing::ContentQualityGate.call(body_text: body)
    assert_not result.pass
    assert_equal :login_page, result.reason
  end

  test "fails consent/cookie page" do
    body = "Este site usa cookies para melhorar sua experiência. Ao continuar navegando, você concorda com a nossa política de cookies e privacidade. LGPD consent required. Aceitar cookies para continuar. Cookie preferences and privacy settings available below."
    result = Parsing::ContentQualityGate.call(body_text: body)
    assert_not result.pass
    assert_equal :consent_page, result.reason
  end

  test "passes article that mentions login incidentally" do
    body = "The new login system was launched by the government. " * 10
    result = Parsing::ContentQualityGate.call(body_text: body)
    assert result.pass
  end
end
