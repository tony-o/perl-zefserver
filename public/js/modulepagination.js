$(".pagination a").click(function(){
  var href = $(this).attr("href").substr(1);
  $(".pagination li.active").removeClass("active");
  $(this).parent().addClass("active");
  if($("div#" + href).hasClass("hidden")){
    $("div#documentation, div#buildstats, div#logs").addClass("hidden");
    $("div#" + href).removeClass("hidden");
  }
});
if(window.location.hash.substring(1) != "documentation"){
  var href = window.location.hash.substring(1);
  if($("div#" + href).length){
    $(".pagination li.active").removeClass("active");
    $(".pagination li a[href='#"+href+"']").parent().addClass("active");
    $("div#"+href).removeClass("hidden");
    $("div#documentation").addClass("hidden"); 
  }
}
