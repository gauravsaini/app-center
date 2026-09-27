/// Contract version. Follows SemVer (LLD §10).
///
/// Additive changes (new capability, new optional method with a default)
/// bump minor. Breaking changes bump major; backends declare the major
/// they implement and the host refuses mismatched majors.
const storeContractsVersion = '0.4.0';

/// Major version backends declare via [StoreBackend.contractVersion].
const storeContractsMajor = 0;
