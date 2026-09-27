<?php
$url='http://127.0.0.1:8099/?wc-api=wc_stripe';
$store=getenv('STORE_WEBHOOK_SECRET');
function post($url,$body,$sigsecret){
  $t=time();
  $sig='t='.$t.',v1='.hash_hmac('sha256',$t.'.'.$body,$sigsecret);
  $ch=curl_init($url);
  curl_setopt_array($ch,[CURLOPT_POST=>1,CURLOPT_POSTFIELDS=>$body,
    CURLOPT_HTTPHEADER=>['Content-Type: application/json','Stripe-Signature: '.$sig],
    CURLOPT_RETURNTRANSFER=>1,CURLOPT_HEADER=>1]);
  $r=curl_exec($ch); $code=curl_getinfo($ch,CURLINFO_HTTP_CODE);
  $reached=(bool)preg_match('/X-Reached-Processing: 1/i',$r);
  curl_close($ch);
  return [$code,$reached];
}
$body=json_encode(['id'=>'evt_1','type'=>'payment_intent.succeeded','created'=>time(),'data'=>['object'=>['id'=>'pi_1']]]);
[$c1,$r1]=post($url,$body,$store);                       // correct secret
[$c2,$r2]=post($url,$body,'whsec_ROTATED_wrong_secret'); // wrong (rotated) secret
echo "GOOD signature  -> HTTP $c1  reached_processing=".($r1?'yes':'no')."\n";
echo "WRONG signature -> HTTP $c2  reached_processing=".($r2?'yes':'no')."\n";
