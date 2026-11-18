// Shapes of Apple's signed payloads (only the fields DayLedger uses).
// https://developer.apple.com/documentation/appstoreserverapi/jwstransactiondecodedpayload
// https://developer.apple.com/documentation/appstoreserverapi/jwsrenewalinfodecodedpayload
// https://developer.apple.com/documentation/appstoreservernotifications/responsebodyv2decodedpayload

export type AppleEnvironment = "Sandbox" | "Production" | "Xcode" | "LocalTesting";

/** offerType values. 1 = introductory offer (our 7-day free trial). */
export const OFFER_TYPE_INTRODUCTORY = 1;

export interface JWSTransaction {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  environment: AppleEnvironment;
  appAccountToken?: string;
  purchaseDate?: number;
  originalPurchaseDate?: number;
  expiresDate?: number;
  signedDate?: number;
  type?: string;
  offerType?: number;
  offerDiscountType?: string;
  revocationDate?: number;
  revocationReason?: number;
  isUpgraded?: boolean;
  subscriptionGroupIdentifier?: string;
  inAppOwnershipType?: string;
}

export interface JWSRenewalInfo {
  originalTransactionId: string;
  productId?: string;
  autoRenewProductId?: string;
  /** 1 = will renew, 0 = turned off. */
  autoRenewStatus?: number;
  isInBillingRetryPeriod?: boolean;
  gracePeriodExpiresDate?: number;
  expirationIntent?: number;
  renewalDate?: number;
  offerType?: number;
  environment?: AppleEnvironment;
  signedDate?: number;
}

export interface NotificationData {
  appAppleId?: number;
  bundleId?: string;
  bundleVersion?: string;
  environment?: AppleEnvironment;
  signedTransactionInfo?: string;
  signedRenewalInfo?: string;
  status?: number;
}

export interface NotificationSummary {
  appAppleId?: number;
  bundleId?: string;
  environment?: AppleEnvironment;
  productId?: string;
  requestIdentifier?: string;
}

export interface NotificationPayload {
  notificationType: string;
  subtype?: string;
  notificationUUID: string;
  version?: string;
  signedDate: number;
  data?: NotificationData;
  summary?: NotificationSummary;
}

/** GET /inApps/v1/subscriptions/{transactionId} response. */
export interface SubscriptionStatusesResponse {
  environment: AppleEnvironment;
  bundleId: string;
  appAppleId?: number;
  data: Array<{
    subscriptionGroupIdentifier: string;
    lastTransactions: Array<{
      originalTransactionId: string;
      /** 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked. */
      status: number;
      signedTransactionInfo: string;
      signedRenewalInfo?: string;
    }>;
  }>;
}
