
/**
 * Carrier Sense Multiple Access implementation
 * Rather than use an IO line to measure CCA, we rely directly on the radio
 * hardware to sample the CCA for us when attempting to transmit. 
 *
 * @author David Moss
 */
 
#include "Blaze.h"
#include "Csma.h"

module CsmaP {
  provides {
    interface Send[radio_id_t radioId];
    interface Csma[am_id_t amId];
  }
  
  uses {
    interface Resource;
    interface AsyncSend[radio_id_t id];
    interface Alarm<T32khz,uint32_t> as BackoffTimer;
    interface BlazePacketBody;
    interface Random;
    interface State;
  }
}

implementation {

  /** The radio we're servicing */
  radio_id_t myRadio;
  
  /** The message we're sending */
  message_t *myMsg;
  
  
  /** The amount of time to currently backoff initially */
  uint16_t myInitialBackoff;
  
  /** The amount of time to currently backoff during congestion */
  uint16_t myCongestionBackoff;
  
  /** TRUE if the current packet should use clear channel assessments */
  bool useCca;
  
  
  enum {
    S_IDLE,
    S_LOADING,
    S_BACKOFF,
    S_FORCING,
  };
  
  /**************** Tasks ****************/
  task void forceSend();
  task void sendDone();
  
  void requestCca();
  void requestInitialBackoff();
  void requestCongestionBackoff();
  
  void initialBackoff();
  void congestionBackoff();
  
  /**************** Send Commands ****************/
  /**
   * By this point, the length should already be set in the message itself.
   * @param msg the message to send
   * @param len IGNORED
   * @return SUCCESS if we're going to try to send the message.
   *     FAIL if you need to reevaluate your code
   */
  command error_t Send.send[radio_id_t id](message_t* msg, uint8_t len) {    
    if(call State.requestState(S_LOADING) != SUCCESS) {
      return FAIL;
    }
    
    atomic {
      myMsg = msg;
      myRadio = id;
    }
    
    // Request the resource to load the TX FIFO.
    // Then, if we're going to backoff, release the resource and get it after
    // the backoff period.  Otherwise, keep the resource to force the tx.
    call Resource.request();      
    
    return SUCCESS;
  }

  command error_t Send.cancel[radio_id_t id](message_t* msg) {
    return FAIL;
  }

  command uint8_t Send.maxPayloadLength[radio_id_t id]() { 
    return TOSH_DATA_LENGTH;
  }

  command void *Send.getPayload[radio_id_t id](message_t* msg) {
    return msg->data;
  }
  
  /***************** Resource Events ****************/
  event void Resource.granted() {
    if(call State.isState(S_LOADING)) {
      call AsyncSend.load[myRadio](myMsg);
    
    } else if(call State.isState(S_BACKOFF)) {
      if(call AsyncSend.send[myRadio]() != SUCCESS) {
        call Resource.release();
        congestionBackoff();
      }
    }
  }
  
  /***************** AsyncSend Events ****************/
  async event void AsyncSend.loadDone[radio_id_t id](void *msg, error_t error) {
    requestCca();
    
    if(!useCca) {
      call State.forceState(S_FORCING);
      post forceSend();
      
    } else {
      call State.forceState(S_BACKOFF);
      call Resource.release();
      initialBackoff();
    }
  }
  
  async event void AsyncSend.sendDone[radio_id_t id]() {
    post sendDone();
  }
  
  /***************** Csma Commands ****************/
  /**
   * Must be called within a requestInitialBackoff event
   * @param backoffTime the amount of time in some unspecified units to backoff
   */
  async command void Csma.setInitialBackoff[am_id_t amId](uint16_t backoffTime) {
    myInitialBackoff = backoffTime + 1;
  }
  
  /**
   * Must be called within a requestCongestionBackoff event
   * @param backoffTime the amount of time in some unspecified units to backoff
   */
  async command void Csma.setCongestionBackoff[am_id_t amId](uint16_t backoffTime) {
    myCongestionBackoff = backoffTime + 1;
  }
  
  /**
   * Must be called within a requestCca event
   * @param cca TRUE to use cca for the outbound packet, FALSE to not use CCA
   */
  async command void Csma.setCca[am_id_t amId](bool cca) {
    useCca = cca;
  }
  

  /***************** BackoffTimer Events ****************/
  async event void BackoffTimer.fired() {
    radio_id_t atomicId;
    
    if(!call State.isState(S_BACKOFF)) {
      // not my event to handle
      return;
    }
    
    atomic atomicId = myRadio;
    
    call Resource.request();
  }
  
  /***************** Tasks ****************/
  /**
   * The radio is programmed up to only Tx on CCA, which we're not going
   * to change.  Plus, it would be pointless to try to transmit while something
   * is talking on the channel anyway.  So we keep trying repetitively until
   * the message sends.
   *
   * If what you're interested in is a jammer, then you need to edit 
   * some of the default register settings for this radio to disable the 
   * hardware CCA.
   */
  task void forceSend() {
    if(call AsyncSend.send[myRadio]() != SUCCESS) {
      post forceSend();
    }
  }
  
  task void sendDone() {
    call Resource.release();
    call State.toIdle();
    signal Send.sendDone[myRadio](myMsg, SUCCESS);
  }
  
  
  /**
   * Decide whether or not to use CCA for this transmission.
   * When complete, the useCca variable will read TRUE to use CCA and FALSE
   * to not use software CCA. 
   */
  void requestCca() {
    useCca = TRUE;
    signal Csma.requestCca[(call BlazePacketBody.getHeader(myMsg))->type](myMsg);
  }
  
  /**
   * Obtain an inital backoff amount.
   * When complete, the variable myInitialBackoff will be filled with the
   * correct amount of initial backoff time to use
   */
  void requestInitialBackoff() {
    myInitialBackoff = ( call Random.rand16() % 
        (0x1F * BLAZE_BACKOFF_PERIOD) + BLAZE_MIN_BACKOFF);
        
    signal Csma.requestInitialBackoff[(call BlazePacketBody.getHeader(myMsg))->type](myMsg);
  }
  
  /**
   * Obtain a congestion backoff amount
   * When complete, the variable myCongestionBackoff will be filled with the
   * correct amount of congestion backoff time to use.
   */
  void requestCongestionBackoff() {
    myCongestionBackoff = ( call Random.rand16() % 
        (0x7 * BLAZE_BACKOFF_PERIOD) + BLAZE_MIN_BACKOFF);
    
    signal Csma.requestCongestionBackoff[(call BlazePacketBody.getHeader(myMsg))->type](myMsg);
  }
  
  
  /**
   * Backoff for the initial backoff period of time
   */
  void initialBackoff() {
    requestInitialBackoff();
    call BackoffTimer.start( myInitialBackoff );
  }
  
  /**
   * Backoff because of a congested channel
   */
  void congestionBackoff() {
    requestCongestionBackoff();
    call BackoffTimer.start( myCongestionBackoff );
  }
  
  
  /***************** Defaults ****************/
  default event void Send.sendDone[radio_id_t id](message_t* msg, error_t error) { }
  
  default async command error_t AsyncSend.load[radio_id_t id](void *msg) { }
  default async command error_t AsyncSend.send[radio_id_t id]() { }
  
  default async event void Csma.requestInitialBackoff[am_id_t amId](message_t *msg) { }
  default async event void Csma.requestCongestionBackoff[am_id_t amId](message_t *msg) { }
  default async event void Csma.requestCca[am_id_t amId](message_t *msg) { }
  
  
}

