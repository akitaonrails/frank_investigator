require "test_helper"

class Analyzers::ClaimNoiseFilterTest < ActiveSupport::TestCase
  # --- Valid claims (not noise) ---

  test "accepts factual claim about GDP" do
    assert_not Analyzers::ClaimNoiseFilter.noise?("Brazil's GDP grew 3.1% in the first quarter of 2025, according to IBGE data.")
  end

  test "accepts factual claim about taxes" do
    assert_not Analyzers::ClaimNoiseFilter.noise?("City Hall announced taxes will fall by 4 percent in 2026.")
  end

  test "accepts claim in Portuguese" do
    assert_not Analyzers::ClaimNoiseFilter.noise?("O PIB do Brasil cresceu 3,1% no primeiro trimestre de 2025, segundo dados do IBGE.")
  end

  # --- UI boilerplate ---

  test "rejects cookie consent text" do
    assert Analyzers::ClaimNoiseFilter.noise?("We use cookies to improve your experience on our site.")
  end

  test "rejects newsletter signup" do
    assert Analyzers::ClaimNoiseFilter.noise?("Subscribe to our newsletter for the latest updates.")
  end

  test "rejects login prompt" do
    assert Analyzers::ClaimNoiseFilter.noise?("Sign in to access your account and manage your preferences.")
  end

  test "rejects app download prompt" do
    assert Analyzers::ClaimNoiseFilter.noise?("Baixe o app e fique por dentro das últimas notícias.")
  end

  test "rejects social share text" do
    assert Analyzers::ClaimNoiseFilter.noise?("Compartilhe no Facebook e Twitter para seus amigos verem.")
  end

  # --- Metadata ---

  test "rejects author byline" do
    assert Analyzers::ClaimNoiseFilter.noise?("Por João Silva da Redação em Brasília")
  end

  test "rejects English byline" do
    assert Analyzers::ClaimNoiseFilter.noise?("By Maria Santos, special correspondent")
  end

  test "rejects update timestamp" do
    assert Analyzers::ClaimNoiseFilter.noise?("Atualizado há 2 horas atrás com novas informações")
  end

  test "rejects date-only string" do
    assert Analyzers::ClaimNoiseFilter.noise?("10/03/2025")
  end

  # --- Portal boilerplate ---

  test "rejects Fala.BR portal text" do
    assert Analyzers::ClaimNoiseFilter.noise?("Fala.BR é a plataforma de ouvidoria do governo federal.")
  end

  test "rejects Plataforma Integrada text" do
    assert Analyzers::ClaimNoiseFilter.noise?("Acesse a Plataforma Integrada de Ouvidoria para registrar sua manifestação.")
  end

  # --- Fragment too short ---

  test "rejects short fragment without verb" do
    assert Analyzers::ClaimNoiseFilter.noise?("Apesar da queda")
  end

  test "accepts short text with verb" do
    assert_not Analyzers::ClaimNoiseFilter.noise?("GDP growth was confirmed")
  end

  # --- Concatenated headlines ---

  test "rejects concatenated headline artifacts" do
    text = "Economia em Alta | Política Nacional | Esportes Hoje | Mundo em Crise"
    assert Analyzers::ClaimNoiseFilter.noise?(text)
  end
end
