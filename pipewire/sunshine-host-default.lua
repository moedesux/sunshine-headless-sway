-- Exclude capture sinks BEFORE default selection, without preventing explicit
-- game/capture targets from using them. Desktop streams must never move here.
SimpleEventHook {
  name = "sunshine/filter-default-candidates",
  before = {
    "default-nodes/find-selected-default-node",
    "default-nodes/find-stored-default-node",
    "default-nodes/find-best-default-node",
  },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
    },
  },
  execute = function (event)
    local nodes = event:get_data ("available-nodes")
    if not nodes then return end
    local host_nodes = {}
    for _, props in ipairs (nodes:parse ()) do
      local name = props["node.name"] or ""
      if not name:match ("^sink%-sunshine%-") then
        table.insert (host_nodes, Json.Object (props))
      end
    end
    event:set_data ("available-nodes", Json.Array (host_nodes))

    -- Sunshine's default request must not discard the current physical-output
    -- choice in favour of a different device with a higher priority.
    -- Repair configured metadata before any effective default is published.
    local kind = event:get_properties ()["default-node.type"]
    if kind ~= "audio.sink" then return end
    local om = event:get_source ():call ("get-object-manager", "metadata")
    local metadata = om:lookup { Constraint { "metadata.name", "=", "default" } }
    if not metadata then return end
    local configured = metadata:find (0, "default.configured.audio.sink")
    local current = metadata:find (0, "default.audio.sink")
    if not configured or not current then return end
    local requested = Json.Raw (configured):parse ().name or ""
    local previous = Json.Raw (current):parse ().name
    if not requested:match ("^sink%-sunshine%-") then return end
    for _, props in ipairs (nodes:parse ()) do
      if props["node.name"] == previous and not previous:match ("^sink%-sunshine%-") then
        metadata:set (0, "default.configured.audio.sink", "Spa:String:JSON", current)
        break
      end
    end
  end,
}:register ()
