#!/bin/bash

cat > org/jivesoftware/smack/ReconnectionManager.java <<EOF
/*   Copyright (c) 2015 Magnet Systems, Inc.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */
package org.jivesoftware.smack;

import java.util.Random;

import org.jivesoftware.smack.AbstractConnectionListener;
import org.jivesoftware.smack.ConnectionCreationListener;
import org.jivesoftware.smack.ConnectionListener;
import org.jivesoftware.smack.XMPPConnection;
import org.jivesoftware.smack.XMPPException.StreamErrorException;
import org.jivesoftware.smack.packet.StreamError;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.util.Log;

/**
 * Handles the automatic reconnection process for Android. Every time a
 * connection is dropped without the application explicitly closing it, the
 * manager automatically tries to reconnect to the server.<p>
 *
 * The reconnection is based on WiFi or Telephony connectivity.  If there is
 * connectivity but still unable to connect, it will retry with non-linear
 * intervals.
 */
public class ReconnectionManager extends AbstractConnectionListener {
  
//  private static void dumpBundle(Bundle bundle) {
//    for (String key : bundle.keySet()) {
//      Object obj = bundle.get(key);
//      Log.d(TAG, "Bundle: "+key+"="+obj);
//    }
//  }
  
  public class NetworkReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
      // Only interested in connected WiFi, Mobile and WiMax.
      if (intent.getBooleanExtra(ConnectivityManager.EXTRA_NO_CONNECTIVITY, false)) {
        return;
      }
      ConnectivityManager conMgr = (ConnectivityManager)
        context.getSystemService(Context.CONNECTIVITY_SERVICE);
      NetworkInfo netInfo = conMgr.getActiveNetworkInfo();
      if (netInfo == null || !netInfo.isConnected()) {
        return;
      }
      int netType = netInfo.getType();
      // TODO: Bluetooth is only for IoT devices, not interested for now.
      if (netType == ConnectivityManager.TYPE_WIFI ||
          netType == ConnectivityManager.TYPE_MOBILE ||
          netType == ConnectivityManager.TYPE_WIMAX) {
        ReconnectionManager.this.reconnect();
      }
    }
  }

  public class DataConnectivityMonitor {
    private boolean mStarted;
    private ConnectivityManager mConMgr;
    private NetworkReceiver mNetworkReceiver;
    
    DataConnectivityMonitor(Context context) {
      mNetworkReceiver = new NetworkReceiver();
      mConMgr = (ConnectivityManager) context.getSystemService(
          Context.CONNECTIVITY_SERVICE);
    }
    
    public void start() {
      if (mStarted) {
        return;
      }
      mContext.registerReceiver(mNetworkReceiver, 
          new IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION));
      mStarted = true;
    }
    
    public void stop() {
      if (!mStarted) {
        return;
      }
      mContext.unregisterReceiver(mNetworkReceiver);
      mStarted = false;
    }

    public boolean hasConnectivity() {
      NetworkInfo info = mConMgr.getActiveNetworkInfo();
      return (info != null) && info.isConnected();
    }
  }
  
  private static final String TAG = ReconnectionManager.class.getSimpleName();
  private XMPPConnection mConnection;
  private Thread mReconnectionThread;
  private Context mContext;
  private boolean mDone;
  private int mRandomBase = new Random().nextInt(11) + 5; // between 5 and 15 seconds
  private DataConnectivityMonitor mDataMonitor;

  static {
    XMPPConnection.addConnectionCreationListener(new ConnectionCreationListener() {
      public void connectionCreated(XMPPConnection connection) {
        connection.addConnectionListener(new ReconnectionManager(connection));
      }
    });
  }

  private ReconnectionManager(XMPPConnection connection) {
    mConnection = connection;
    mContext = SmackAndroid.getInstance().getContext();
    mDataMonitor = new DataConnectivityMonitor(mContext);
  }
  
  private boolean isReconnectionAllowed() {
    return !mDone && !mConnection.isConnected() &&
            mConnection.getConfiguration().isReconnectionAllowed();
  }

  @Override
  public void connectionClosed() {
    mDone = true;
    mDataMonitor.stop();
  }
  
  public void connectionClosedOnError(Exception e) {
    mDone = false;
    if (e instanceof StreamErrorException) {
      StreamErrorException xmppEx = (StreamErrorException) e;
      StreamError error = xmppEx.getStreamError();
      String reason = error.getCode();

      if ("conflict".equals(reason)) {
        return;
      }
    }

    if (this.isReconnectionAllowed()) {
      if (mDataMonitor.hasConnectivity()) {
        this.reconnect();
      } else {
        mDataMonitor.start();
      }
    }
  }
  
  // Do the reconnection.  If there is an on-going reconnection, no need to
  // start another reconnection.  Otherwise, try to establish a connection.
  // If it fails because of no connectivity, start monitoring the connectivity.
  // If it fails for other reasons, retry the reconnection with non-linear intervals.
  synchronized protected void reconnect() {
    if (!this.isReconnectionAllowed()) {
      return;
    }
    mDataMonitor.stop();

    if (mReconnectionThread != null && mReconnectionThread.isAlive()) {
      return;
    }
    mReconnectionThread = new Thread() {
      // Holds the current number of reconnection attempts
      private int mAttempts = 0;

      /**
       * Returns the number of seconds until the next reconnection attempt.
       * @return the number of seconds until the next reconnection attempt.
       */
      private int timeDelay() {
        mAttempts++;
        if (mAttempts > 13) {
          return mRandomBase * 6 * 5; // between 2.5 and 7.5 minutes (~5 minutes)
        }
        if (mAttempts > 7) {
          return mRandomBase * 6; // between 30 and 90 seconds (~1 minutes)
        }
        return mRandomBase; // 10 seconds
      }
      
      public void run() {
        // The process will try to reconnect until the connection is established
        // or the user cancel the reconnection process {@link XMPPConnection#disconnect()}
        while (ReconnectionManager.this.isReconnectionAllowed()) {
          // Find how much time we should wait until the next reconnection
          int remainingSeconds = timeDelay();
          // Connect first.  If it failed because of no connectivity, start the
          // connectivity monitor again.  Otherwise, sleep until we're ready for
          // the next reconnection attempt. Notify listeners once per second
          // about how much time remains before the next reconnection attempt.
          while (ReconnectionManager.this.isReconnectionAllowed() &&
                 remainingSeconds > 0) {
            // Makes a reconnection attempt
            try {
              if (ReconnectionManager.this.isReconnectionAllowed()) {
                mConnection.connect();
              }
            } catch (Exception e) {
              if (!mDataMonitor.hasConnectivity()) {
                // Reconnection failed because of no connectivity, start
                // monitoring the connectivity using Connectivity Service.
                mDataMonitor.start();
                break;
              }
              // Fires the failed reconnection notification
              ReconnectionManager.this.notifyReconnectionFailed(e);
            }
            
            try {
              Thread.sleep(1000);
              remainingSeconds--;
              ReconnectionManager.this
                  .notifyAttemptToReconnectIn(remainingSeconds);
            } catch (InterruptedException e1) {
              Log.w(TAG, "Sleeping thread interrupted");
              // Notify the reconnection has failed
              ReconnectionManager.this.notifyReconnectionFailed(e1);
            }
          }
        }
      }
    };

    mReconnectionThread.setName("Asmack Reconnection Manager");
    mReconnectionThread.setDaemon(true);
    mReconnectionThread.start();
  }
  
  /**
   * Fires listeners when a reconnection attempt has failed.
   *
   * @param exception the exception that occurred.
   */
  protected void notifyReconnectionFailed(Exception exception) {
    if (isReconnectionAllowed()) {
      for (ConnectionListener listener : mConnection.connectionListeners) {
        listener.reconnectionFailed(exception);
      }
    }
  }
  
  /**
   * Fires listeners when The XMPPConnection will retry a reconnection.
   * Expressed in seconds.
   *
   * @param seconds the number of seconds that a reconnection will be
   *         attempted in.
   */
  protected void notifyAttemptToReconnectIn(int seconds) {
    if (isReconnectionAllowed()) {
      for (ConnectionListener listener : mConnection.connectionListeners) {
        listener.reconnectingIn(seconds);
      }
    }
  }
}
EOF
