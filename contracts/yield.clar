;; Decentralized Yield Farming Protocol
;; Stake tokens, earn rewards, and maximize your DeFi returns

;; Constants
(define-constant PROTOCOL_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED_USER (err u100))
(define-constant ERR_POOL_NOT_ACTIVE (err u102))
(define-constant ERR_INSUFFICIENT_BALANCE (err u103))
(define-constant ERR_INVALID_STAKE_AMOUNT (err u104))
(define-constant ERR_NO_REWARDS_AVAILABLE (err u105))
(define-constant ERR_NO_STAKE_FOUND (err u106))
(define-constant ERR_LOCKUP_PERIOD_ACTIVE (err u107))
(define-constant ERR_POOL_NOT_MATURE (err u108))
(define-constant ERR_REWARDS_ALREADY_DISTRIBUTED (err u109))
(define-constant ERR_INVALID_POOL_DURATION (err u110))
(define-constant ERR_INVALID_REWARD_RATE (err u111))
(define-constant ERR_INVALID_STAKER_ID (err u112))
(define-constant ERR_POOL_ALREADY_RUNNING (err u113))
(define-constant ERR_COOLDOWN_PERIOD_ACTIVE (err u114))

;; Data Variables
(define-data-var farming-pool-active bool false)
(define-data-var minimum-stake-required uint u100000000) ;; 100 STX minimum
(define-data-var total-value-locked uint u0)
(define-data-var active-stakers-count uint u0)
(define-data-var reward-tokens-per-block uint u1000) ;; 0.001 STX per block
(define-data-var pool-maturity-block uint u0)
(define-data-var early-withdrawal-penalty uint u10) ;; 10% penalty
(define-data-var protocol-treasury-fee uint u3) ;; 3% protocol fee
(define-data-var individual-reward-rate uint u0)
(define-data-var rewards-distribution-complete bool false)
(define-data-var farming-epochs-completed uint u0)
(define-data-var compound-interest-multiplier uint u105) ;; 1.05x multiplier

;; Maps
(define-map stake-positions {position-id: uint} {staker: principal, amount: uint, entry-block: uint})
(define-map staker-balances principal {staked-amount: uint, earned-rewards: uint, last-claim-block: uint})
(define-map reward-recipients {recipient-id: uint} {address: principal, rewards-claimed: bool, total-earned: uint})
(define-map epoch-analytics {epoch: uint} {total-staked: uint, rewards-distributed: uint, participants: uint, apy-rate: uint})
(define-map staker-lockup principal uint) ;; Lockup periods for different stakers

;; Private Functions
(define-private (verify-protocol-authority)
  (is-eq tx-sender PROTOCOL_OWNER))

(define-private (ensure-pool-operational)
  (if (var-get farming-pool-active)
    (ok true)
    ERR_POOL_NOT_ACTIVE))

(define-private (validate-user-balance (required-tokens uint))
  (if (>= (stx-get-balance tx-sender) required-tokens)
    (ok true)
    ERR_INSUFFICIENT_BALANCE))

(define-private (calculate-staking-rewards (staked-tokens uint) (blocks-elapsed uint))
  (* (* staked-tokens (var-get reward-tokens-per-block)) blocks-elapsed))

(define-private (transfer-rewards-to-staker (recipient-address principal) (reward-amount uint))
  (as-contract (stx-transfer? reward-amount tx-sender recipient-address)))

(define-private (calculate-protocol-fee (total-rewards uint))
  (/ (* total-rewards (var-get protocol-treasury-fee)) u100))

(define-private (apply-compound-interest (base-amount uint))
  (/ (* base-amount (var-get compound-interest-multiplier)) u100))

;; Public Functions
(define-public (launch-farming-epoch (duration-blocks uint) (min-stake uint) (reward-rate uint) (penalty-rate uint) (treasury-fee uint))
  (begin
    (asserts! (verify-protocol-authority) ERR_UNAUTHORIZED_USER)
    (asserts! (> min-stake u0) ERR_INVALID_STAKE_AMOUNT)
    (asserts! (> reward-rate u0) ERR_INVALID_REWARD_RATE)
    (asserts! (<= treasury-fee u15) ERR_UNAUTHORIZED_USER) ;; Max 15% treasury fee
    (asserts! (not (var-get farming-pool-active)) ERR_POOL_ALREADY_RUNNING)
    (asserts! (> duration-blocks u0) ERR_INVALID_POOL_DURATION)
    (var-set farming-pool-active true)
    (var-set minimum-stake-required min-stake)
    (var-set total-value-locked u0)
    (var-set active-stakers-count u0)
    (var-set reward-tokens-per-block reward-rate)
    (var-set pool-maturity-block (+ block-height duration-blocks))
    (var-set early-withdrawal-penalty penalty-rate)
    (var-set protocol-treasury-fee treasury-fee)
    (var-set rewards-distribution-complete false)
    (ok true)))

(define-public (deposit-stake-tokens)
  (let ((stake-amount (var-get minimum-stake-required)))
    (begin
      (try! (ensure-pool-operational))
      (try! (validate-user-balance stake-amount))
      (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
      (var-set total-value-locked (+ (var-get total-value-locked) stake-amount))
      (var-set active-stakers-count (+ (var-get active-stakers-count) u1))
      (map-set stake-positions {position-id: (var-get active-stakers-count)} 
               {staker: tx-sender, amount: stake-amount, entry-block: block-height})
      (let ((current-balance (default-to {staked-amount: u0, earned-rewards: u0, last-claim-block: u0} 
                                        (map-get? staker-balances tx-sender))))
        (map-set staker-balances tx-sender 
                 {staked-amount: (+ (get staked-amount current-balance) stake-amount),
                  earned-rewards: (get earned-rewards current-balance),
                  last-claim-block: block-height}))
      (ok (var-get active-stakers-count)))))

(define-public (withdraw-staked-tokens (withdrawal-amount uint))
  (let ((user-balance (default-to {staked-amount: u0, earned-rewards: u0, last-claim-block: u0} 
                                  (map-get? staker-balances tx-sender)))
        (staked-tokens (get staked-amount user-balance))
        (penalty-amount (if (< block-height (var-get pool-maturity-block))
                           (/ (* withdrawal-amount (var-get early-withdrawal-penalty)) u100)
                           u0))
        (net-withdrawal (- withdrawal-amount penalty-amount)))
    (begin
      (try! (ensure-pool-operational))
      (asserts! (>= staked-tokens withdrawal-amount) ERR_NO_STAKE_FOUND)
      (asserts! (is-none (map-get? staker-lockup tx-sender)) ERR_LOCKUP_PERIOD_ACTIVE)
      (var-set total-value-locked (- (var-get total-value-locked) withdrawal-amount))
      (map-set staker-balances tx-sender 
               {staked-amount: (- staked-tokens withdrawal-amount),
                earned-rewards: (get earned-rewards user-balance),
                last-claim-block: (get last-claim-block user-balance)})
      (if (> penalty-amount u0)
        (as-contract (stx-transfer? penalty-amount tx-sender PROTOCOL_OWNER))
        (ok true))
      (as-contract (stx-transfer? net-withdrawal tx-sender tx-sender)))))

(define-public (finalize-farming-epoch)
  (let ((total-staked (var-get total-value-locked))
        (stakers-count (var-get active-stakers-count))
        (protocol-fee (calculate-protocol-fee total-staked))
        (current-epoch (+ (var-get farming-epochs-completed) u1)))
    (begin
      (asserts! (verify-protocol-authority) ERR_UNAUTHORIZED_USER)
      (asserts! (>= block-height (var-get pool-maturity-block)) ERR_POOL_NOT_MATURE)
      (try! (ensure-pool-operational))
      (asserts! (> stakers-count u0) ERR_NO_REWARDS_AVAILABLE)
      (var-set farming-pool-active false)
      (try! (as-contract (stx-transfer? protocol-fee tx-sender PROTOCOL_OWNER)))
      (let ((rewards-pool (- total-staked protocol-fee)))
        (var-set individual-reward-rate (/ rewards-pool stakers-count)))
      (map-set epoch-analytics {epoch: current-epoch}
               {total-staked: total-staked, rewards-distributed: (- total-staked protocol-fee), 
                participants: stakers-count, apy-rate: (var-get reward-tokens-per-block)})
      (var-set farming-epochs-completed current-epoch)
      (ok true))))

(define-public (distribute-yield-rewards (randomness-seed uint))
  (let ((stakers-count (var-get active-stakers-count))
        (total-staked (var-get total-value-locked)))
    (begin
      (asserts! (verify-protocol-authority) ERR_UNAUTHORIZED_USER)
      (asserts! (not (var-get farming-pool-active)) ERR_POOL_NOT_ACTIVE)
      (asserts! (not (var-get rewards-distribution-complete)) ERR_REWARDS_ALREADY_DISTRIBUTED)
      (asserts! (> stakers-count u0) ERR_NO_REWARDS_AVAILABLE)
      (var-set rewards-distribution-complete true)
      (let ((distribution-result (fold process-reward-distribution
                                       (list u0 u1 u2 u3 u4 u5 u6 u7 u8 u9)
                                       {seed: randomness-seed, recipient-counter: u0, remaining-rewards: stakers-count})))
        (ok (get recipient-counter distribution-result))))))

(define-private (process-reward-distribution (index uint) (context {seed: uint, recipient-counter: uint, remaining-rewards: uint}))
  (if (> (get remaining-rewards context) u0)
    (let ((reward-recipient-id (mod (+ (get seed context) index) (var-get active-stakers-count)))
          (position-info (unwrap-panic (map-get? stake-positions {position-id: (+ reward-recipient-id u1)})))
          (recipient-address (get staker position-info))
          (base-reward (var-get individual-reward-rate))
          (compounded-reward (apply-compound-interest base-reward)))
      (begin
        (map-set reward-recipients {recipient-id: (get recipient-counter context)} 
                 {address: recipient-address, rewards-claimed: false, total-earned: compounded-reward})
        {seed: (+ (get seed context) u1),
         recipient-counter: (+ (get recipient-counter context) u1),
         remaining-rewards: (- (get remaining-rewards context) u1)}))
    context))

(define-public (claim-farming-rewards (recipient-id uint))
  (let ((reward-info (unwrap! (map-get? reward-recipients {recipient-id: recipient-id}) ERR_INVALID_STAKER_ID))
        (recipient-address (get address reward-info))
        (rewards-claimed (get rewards-claimed reward-info))
        (total-earned (get total-earned reward-info)))
    (begin
      (asserts! (is-eq tx-sender recipient-address) ERR_UNAUTHORIZED_USER)
      (asserts! (not rewards-claimed) ERR_UNAUTHORIZED_USER)
      (try! (transfer-rewards-to-staker recipient-address total-earned))
      (asserts! (< recipient-id (var-get active-stakers-count)) ERR_INVALID_STAKER_ID)
      (map-set reward-recipients {recipient-id: recipient-id} 
               {address: recipient-address, rewards-claimed: true, total-earned: total-earned})
      (ok true))))

(define-public (set-staker-lockup (lockup-blocks uint))
  (begin
    (try! (ensure-pool-operational))
    (asserts! (> lockup-blocks u0) ERR_INVALID_POOL_DURATION)
    (map-set staker-lockup tx-sender (+ block-height lockup-blocks))
    (ok true)))

(define-public (get-epoch-performance (epoch-number uint))
  (let ((epoch-data (map-get? epoch-analytics {epoch: epoch-number})))
    (ok epoch-data)))

;; Read-Only Functions
(define-read-only (get-minimum-stake)
  (ok (var-get minimum-stake-required)))

(define-read-only (get-total-value-locked)
  (ok (var-get total-value-locked)))

(define-read-only (get-user-stake-info (user-address principal))
  (ok (map-get? staker-balances user-address)))

(define-read-only (get-active-stakers)
  (ok (var-get active-stakers-count)))

(define-read-only (is-farming-active)
  (ok (var-get farming-pool-active)))

(define-read-only (get-pool-maturity-block)
  (ok (var-get pool-maturity-block)))

(define-read-only (get-withdrawal-penalty-rate)
  (ok (var-get early-withdrawal-penalty)))

(define-read-only (get-protocol-fee-rate)
  (ok (var-get protocol-treasury-fee)))

(define-read-only (get-reward-recipient-info (recipient-id uint))
  (ok (map-get? reward-recipients {recipient-id: recipient-id})))

(define-read-only (are-rewards-distributed)
  (ok (var-get rewards-distribution-complete)))

(define-read-only (get-total-epochs-completed)
  (ok (var-get farming-epochs-completed)))

(define-read-only (get-current-apy-rate)
  (ok (var-get reward-tokens-per-block)))

(define-read-only (get-staker-lockup-status (staker-address principal))
  (ok (map-get? staker-lockup staker-address)))

(define-read-only (calculate-potential-rewards (staker-address principal))
  (let ((user-balance (map-get? staker-balances staker-address)))
    (match user-balance
      balance (let ((staked-amount (get staked-amount balance))
                    (last-claim (get last-claim-block balance))
                    (blocks-since-claim (- block-height last-claim)))
                (ok (calculate-staking-rewards staked-amount blocks-since-claim)))
      (ok u0))))