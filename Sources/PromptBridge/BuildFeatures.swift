enum BuildFeatures {
    #if PROMPTBRIDGE_TESTING
    static let testing = true
    #else
    static let testing = false
    #endif
}
