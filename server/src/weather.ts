/**
 * Real current weather via Open-Meteo (free, no API key needed).
 * Docs: https://open-meteo.com/en/docs
 */

const WMO_DESCRIPTIONS: Record<number, string> = {
  0: "cielo despejado",
  1: "mayormente despejado",
  2: "parcialmente nublado",
  3: "nublado",
  45: "niebla",
  48: "niebla helada",
  51: "llovizna ligera",
  53: "llovizna moderada",
  55: "llovizna intensa",
  61: "lluvia ligera",
  63: "lluvia moderada",
  65: "lluvia intensa",
  71: "nieve ligera",
  73: "nieve moderada",
  75: "nieve intensa",
  80: "chubascos ligeros",
  81: "chubascos moderados",
  82: "chubascos violentos",
  95: "tormenta",
  96: "tormenta con granizo",
  99: "tormenta fuerte con granizo"
};

export async function fetchWeather(location: string): Promise<string> {
  const geoUrl = new URL("https://geocoding-api.open-meteo.com/v1/search");
  geoUrl.searchParams.set("name", location);
  geoUrl.searchParams.set("count", "1");
  geoUrl.searchParams.set("language", "es");
  geoUrl.searchParams.set("format", "json");

  const geoRes = await fetch(geoUrl);
  if (!geoRes.ok) return `No pude buscar la ubicación "${location}".`;
  const geoData: any = await geoRes.json();
  const place = geoData?.results?.[0];
  if (!place) return `No encontré ningún sitio llamado "${location}".`;

  const forecastUrl = new URL("https://api.open-meteo.com/v1/forecast");
  forecastUrl.searchParams.set("latitude", String(place.latitude));
  forecastUrl.searchParams.set("longitude", String(place.longitude));
  forecastUrl.searchParams.set("current", "temperature_2m,wind_speed_10m,relative_humidity_2m,weather_code");
  forecastUrl.searchParams.set("timezone", "auto");

  const forecastRes = await fetch(forecastUrl);
  if (!forecastRes.ok) return `Encontré "${place.name}" pero no pude consultar el tiempo ahora mismo.`;
  const forecastData: any = await forecastRes.json();
  const current = forecastData?.current;
  if (!current) return `Encontré "${place.name}" pero no hay datos de tiempo disponibles ahora mismo.`;

  const description = WMO_DESCRIPTIONS[current.weather_code] ?? "condiciones variables";
  const placeLabel = [place.name, place.admin1, place.country].filter(Boolean).join(", ");

  return `En ${placeLabel} ahora mismo: ${description}, ${current.temperature_2m}°C, ` +
    `viento de ${current.wind_speed_10m} km/h, humedad del ${current.relative_humidity_2m}%.`;
}
