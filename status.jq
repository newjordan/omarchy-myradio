# Slim /api/status down to what the panel reads.
# A worker counts as warming only while the studio is still checking it.
# A failed, switched-off or misconfigured maker is not warming: requests for it stay closed.
{
  station: (.station // {}),
  running, elapsed, fading, error,
  current: (.current | if . then {id, title, artist, duration, kind} else null end),
  queue: [(.queue // [])[:12][] | {id, track_id, title, artist, duration, kind}],
  queue_total: ((.queue // []) | length),
  library_total: ((.library // []) | length),
  history: [(.history // [])[:8][] | {title, at, event}],
  health: (.health // {}),
  stats: (.stats // {}),
  listeners: (.stream.listeners // 0),
  broadcast: (.broadcast.state // null),
  broadcast_ready: (.broadcast.configured // false),
  director: (.extensions.director.status // null | if . then {
    enabled, waiting, placed, dropped,
    settings: ((.settings // {}) | {every_songs, station_id_minutes, news_minutes, hosts}),
    requests: [(.requests // [])[] | {key, topic, state, message, track_id, headlines}]
  } else null end),
  generation: (.extensions.generation.status // null | if . then {
    configured, paused, headline, next_step,
    warming: ([(.workers // [])[] | select(.state == "checking" or .state == "warming") | (.roles // [])[]] | unique),
    roles: (.capabilities.roles // {}),
    fixture_roles: (.fixture_roles // []),
    jobs: (.jobs // {}),
    recent: [(.recent // [])[:6][] | {id, role, state, title, error}]
  } else null end)
}
