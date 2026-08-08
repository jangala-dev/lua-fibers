local Base = {}
function Base.init(self, features, close)
  self._features = features
  self._close_backend = close
end
function Base:feature(name) return self._features[name] end
function Base:supports(name) return not not self:feature(name) end
function Base:close()
  if self._closed then return true end
  self._closed = true
  if self._close_backend then return self._close_backend(self) end
  return true
end

return Base
