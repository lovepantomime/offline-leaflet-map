queue = require('queue-async');
IDBStore = require('idb-wrapper');

class OfflineLayer extends L.TileLayer
  initialize: (url, options) ->
    L.TileLayer.prototype.initialize.call(this, url, options)

    @_onReady = options["onReady"]
    @_onError = options["onError"]
    storeName = options["storeName"] || 'OfflineLeafletTileImages'

    @_hasBeenCanceled = false
    @_nbTilesLeftToSave = 0
    @_nbTilesWithError = 0

    try
      # Create the DB store and then call the @_onReady callback
      @_tileImagesStore = new IDBStore({
        dbVersion: 1,
        storeName: storeName,
        keyPath: null,
        autoIncrement: false
      }, @_onReady)
    catch err
      @_reportError("COULD_NOT_CREATE_DB", err)
      setTimeout(
        () =>
          self._onReady()
        , 1000
      )

  _setUpTile: (tile, key, value) ->
    # Start loading the tile with either the cached tile image or the result of getTileUrl
    tile.src = value
    @fire('tileloadstart', {
        tile: tile,
        url: tile.src
      }
    )

  _reportError: (errorType, errorData1, errorData2) ->
    if @_onError
      @_onError(errorType, errorData1, errorData2)

  _loadTile: (tile, tilePoint) ->
    if not @_tileImagesStore
      return L.TileLayer.prototype._loadTile.call(this, tile, tilePoint)

    # Reproducing TileLayer._loadTile behavior, but the tile.src will be set later
    tile._layer = this
    tile.onerror = @_tileOnError
    @_adjustTilePoint(tilePoint)
    tile.onload = @_tileOnLoad
    # Done reproducing _loadTile

    onSuccess = (dbEntry) ->
      if dbEntry
        # if the tile has been cached, use the stored Base64 value
        @_setUpTile(tile, key, dbEntry.image)
      else
        # query the map provider for the tile
        @_setUpTile(tile, key, self.getTileUrl(tilePoint))

    onError = () ->
      # Error while getting the key from the DB
      # will get the tile from the map provider
      self._setUpTile(tile, key, @getTileUrl(tilePoint))
      self._reportError("INDEXED_DB_GET", key)

    key = @_createTileKey(tilePoint.x, tilePoint.y, tilePoint.z)
    # Look for the tile in the DB
    @_tileImagesStore.get(key, onSuccess, onError)

  # called when the total number of tiles is known
  _updateTotalNbImagesLeftToSave: (nbTiles) ->
    @_nbTilesLeftToSave = nbTiles
    @fire('tilecachingprogressstart', {nbTiles: @_nbTilesLeftToSave})


  # called each time a tile as been handled
  _decrementNbTilesLeftToSave: () ->
    @_nbTilesLeftToSave--
    @fire('tilecachingprogress', {nbTiles:@_nbTilesLeftToSave})

  _incrementNbTilesWithError: () ->
    #Not used for now...
    @_nbTilesWithError++

  cancel: () ->
    # no reason to cancel if it's not doing anything
    if(@_myQueue)
      @_hasBeenCanceled = true
      return true

    return false

  clearTiles: () ->
    if(!@_tileImagesStore)
      @_reportError("NO_DB", "No DB available")
      return

    @_tileImagesStore.clear()

  # calculateNbTiles includes potentially already saved tiles.
  calculateNbTiles: (zoomLevelLimit) ->
    count = 0
    tileImagesToQuery = @_getTileImages(zoomLevelLimit)
    for key in tileImagesToQuery
      count++
    return count

  isBusy: () ->
    return @_myQueue or @_hasBeenCanceled

  # Returns the tiles currently displayed
  # @_tiles could return tiles that are currently loaded but not displayed
  # that is why the tiles are recalculated here.
  _getTileImages: (zoomLevelLimit) ->
    zoomLevelLimit = zoomLevelLimit || @_map.getMaxZoom()

    tileImagesToQuery = {}

    map = @_map
    startingZoom = map.getZoom()
    bounds = map.getPixelBounds()
    tileSize = @_getTileSize()

    # bounds are rounded down since a tile cover all the pixels from it's rounded down value until the next tile
    roundedTileBounds = L.bounds(
      bounds.min.divideBy(tileSize)._floor(),
      bounds.max.divideBy(tileSize)._floor()
    )

    tilesInScreen = []

    for j in [roundedTileBounds.min.y .. roundedTileBounds.max.y]
      for i in [roundedTileBounds.min.x .. roundedTileBounds.max.x]
        tilesInScreen.push(new L.Point(i, j))

    # We will use the exact bound values to test if sub tiles are still inside these bounds.
    # The idea is to avoid caching images outside the screen.
    tileBounds = L.bounds(
      bounds.min.divideBy(tileSize),
      bounds.max.divideBy(tileSize)
    )
    minY = tileBounds.min.y
    maxY = tileBounds.max.y
    minX = tileBounds.min.x
    maxX = tileBounds.max.x

    arrayLength = tilesInScreen.length
    for i in [0 ... arrayLength]
      point = tilesInScreen[i]
      x = point.x
      y = point.y
      @_getZoomedInTiles(x, y, startingZoom, zoomLevelLimit, tileImagesToQuery, minY, maxY, minX, maxX)
      @_getZoomedOutTiles(x, y, startingZoom, 0, tileImagesToQuery, minY, maxY, minX, maxX)

    return tileImagesToQuery

  # saves the tiles currently on screen + lower and higher zoom levels.
  saveTiles: (zoomLevelLimit) ->
    if(!@_tileImagesStore)
      @_reportError("NO_DB", "No DB available")
      return

    if(@isBusy())
      alert("system is busy.")
      return

    @_hasBeenCanceled = false

    tileImagesToQuery = @_getTileImages(zoomLevelLimit)

    tileImagesToQueryArray = []
    for key in tileImagesToQuery
      tileImagesToQueryArray.push(key)

    # Query all the needed tiles from the DB
    @_tileImagesStore.getBatch(tileImagesToQueryArray, (items) =>
      # will be loading and saving a maximum of 8 tiles at a time
      @_myQueue = queue(8)
      i = 0
      @fire('tilecachingstart', null)

      @_nbTilesLeftToSave = 0
      items.forEach((item) =>
        if not item
          # that tile image is not present in the DB
          key = tileImagesToQueryArray[i]
          tileInfo = tileImagesToQuery[key]

          @_nbTilesLeftToSave++

          # that call will load the image from the map provider
          makingAjaxCall = (url, callback, error, queueCallback) =>
            if(@_hasBeenCanceled)
              queueCallback()
              return

            ajax(url, callback, error, queueCallback)

          imageUrl = @_createURL(tileInfo.x, tileInfo.y, tileInfo.z)

          # when the image is received, it is stored inside the DB using Base64 format
          gettingImage = (response) =>
            @_tileImagesStore.put(key, {"image": arrayBufferToBase64ImagePNG(response)})
            @_decrementNbTilesLeftToSave()

          errorGettingImage = (errorType, errorData) =>
            @_incrementNbTilesWithError()
            @_decrementNbTilesLeftToSave()
            @_reportError(errorType, errorData, imageUrl)

          # using queue-async to limit the number of simultaneous ajax calls
          @_myQueue.defer(makingAjaxCall, imageUrl, gettingImage, errorGettingImage)

          i++
      )

      @_updateTotalNbImagesLeftToSave(@_nbTilesLeftToSave)

      # wait for all tiles to be saved or found in the DB
      # using dense returns undefined for each entry not present in the DB
      @_myQueue.awaitAll(
        (error, data) =>
          @_hasBeenCanceled = false
          @_myQueue = null
          @fire('tilecachingprogressdone', null)
        ,@_onBatchQueryError, 'dense'
      )
    )

  _getZoomedInTiles: (x, y, currentZ, maxZ, tileImagesToQuery, minY, maxY, minX, maxX) ->
    @_getTileImage(x, y, currentZ, tileImagesToQuery, minY, maxY, minX, maxX, true)

    if currentZ < maxZ
      # getting the 4 tile under the current tile
      minY *= 2
      maxY *= 2
      minX *= 2
      maxX *= 2
      @_getZoomedInTiles(x * 2, y * 2, currentZ + 1, maxZ, tileImagesToQuery, minY, maxY, minX, maxX)
      @_getZoomedInTiles(x * 2 + 1, y * 2, currentZ + 1, maxZ, tileImagesToQuery, minY, maxY, minX, maxX)
      @_getZoomedInTiles(x * 2, y * 2 + 1, currentZ + 1, maxZ, tileImagesToQuery, minY, maxY, minX, maxX)
      @_getZoomedInTiles(x * 2 + 1, y * 2 + 1, currentZ + 1, maxZ, tileImagesToQuery, minY, maxY, minX, maxX)

  _getZoomedOutTiles: (x, y, currentZ, finalZ, tileImagesToQuery, minY, maxY, minX, maxX) ->
    @_getTileImage(x, y, currentZ, tileImagesToQuery, minY, maxY, minX, maxX, false)

    if currentZ > finalZ
      minY /= 2
      maxY /= 2
      minX /= 2
      maxX /= 2
      # getting the zoomed out tile containing this tile
      @_getZoomedOutTiles(Math.floor(x / 2), Math.floor(y / 2), currentZ - 1, finalZ, tileImagesToQuery,
        minY, maxY, minX, maxX)

  _getTileImage: (x, y, z, tileImagesToQuery, minY, maxY, minX, maxX) ->
    # is the tile outside the bounds?
    if x < Math.floor(minX) or x > Math.floor(maxX) or y < Math.floor(minY) or y > Math.floor(maxY)
      return

    # At this point, we only add the image to a "dictionary"
    # This is being done to avoid multiple requests when zooming out, since zooming int should never overlap
    key = @_createTileKey(x, y, z)
    if(!tileImagesToQuery[key])
      tileImagesToQuery[key] = {key:key, x: x, y: y, z: z}

  _onBatchQueryError: (errorData) ->
    @_reportError("INDEXED_DB_BATCH", errorData)

  _createNormalizedTilePoint: (x, y, z) ->
    nbTilesAtZoomLevel = Math.pow(2, z)

    while(x > nbTilesAtZoomLevel)
      x -= nbTilesAtZoomLevel
    while(x < 0)
      x += nbTilesAtZoomLevel

    while(y > nbTilesAtZoomLevel)
      y -= nbTilesAtZoomLevel
    while(y < 0)
      y += nbTilesAtZoomLevel

    return {x: x, y: y, z: z}

  _createURL: (x, y, z) ->
    tilePoint = @_createNormalizedTilePoint(x, y, z)
    return @getTileUrl(tilePoint)

  _createTileKey: (x, y, z) ->
    tilePoint = @_createNormalizedTilePoint(x, y, z)
    return tilePoint.x + ", " + tilePoint.y + ", " + tilePoint.z
